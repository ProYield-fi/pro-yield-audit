// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITokenMessengerV2Burn {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

interface IMessageTransmitterV2Recv {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}

/// @notice The vault hook that books a strategy's returned PRINCIPAL without
/// crediting it as yield (audit F-5). See ProYieldVault.onStrategyReturn.
/// Same shape as SUSD3Strategy's — declared locally because each sleeve is a
/// standalone source unit.
interface IVaultReturnHook {
    function onStrategyReturn(uint256 amount) external;
}

/// @notice Pendle PT fixed-rate sleeve — HyperEVM side (vault-facing).
///
/// Architecture (see docs/PT_SLEEVE_DESIGN.md):
///   vault (HyperEVM) -> THIS contract holds USDC ->
///   CCTP burn (fast, fee-free HyperEVM->Arb) -> PTSleeveExecutor on Arbitrum
///   buys PT via the Pendle router (fixed-rate, hold-to-roll). Value returns
///   through the reverse CCTP path (standard transfer, fee-free) and lands
///   back here as real USDC.
///
/// Accounting model (all balances in USDC 6dp):
///   totalAssets = idle + inFlight6 + arbValue6
///   - `sentFace6` / `retFace6` are monotonic cumulative face flows (`retFace6`
///     counts returned PRINCIPAL only).
///   - `inFlight6`: sent but not yet acknowledged as arrived on
///     the Arb side (counted at face — CCTP mints 1:1; outbound fee is 0 today
///     and `maxFee` is capped at deploy time anyway). `completeInbound` consumes
///     it (audit F-1), so a forgotten `ackArrival` can never 2x `totalAssets()`.
///   - `arbValue6`: keeper-attested value of the Arb position (PT + Arb idle),
///     CLAMPED to arrived-face x (1 + headroom) on every sync — the keeper can
///     never inflate the book beyond what actually left this contract.
///   - Any inbound completion subtracts the received amount from `arbValue6`
///     (never double-counts), and the keeper re-syncs the true remainder.
///   - Yield vs principal: an inbound mint retires outstanding principal first
///     (`retFace6`); any excess is realized yield (`profitRealized6`) and is
///     swept to the vault ONLY through the vault's `harvest()` (`_doHarvest`) —
///     never through `deployToArb`/`pushIdle`/`recall`, which are all capped at
///     `idlePrincipal6()` (= idle balance − `harvestableProfit6()`).
///
/// Trust model: the only money movements out of this contract are
/// (a) CCTP burns to the IMMUTABLE `arbExecutor`, and (b) transfers to the
/// vault. The keeper can poke and attest but cannot redirect a single cent.
contract PTSleeveStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ITokenMessengerV2Burn public immutable tokenMessenger;
    IMessageTransmitterV2Recv public immutable messageTransmitter;
    address public immutable arbExecutor; // CCTP mint target on the destination chain (Arbitrum or Ethereum; immutable)
    uint32 public immutable destDomain; // CCTP destination domain — Arbitrum = 3, Ethereum = 0

    uint256 public constant MAX_HEADROOM_BPS = 3000; // hard cap: +30%
    uint256 public headroomBps = 2000; // default attestation headroom: +20%
    uint256 public minBridgeUsd6 = 5e6; // never bridge dust ($5)
    uint256 public constant MAX_BURN_FEE6 = 2e6; // keeper maxFee arg cap ($2)

    uint256 public sentFace6; // cumulative face sent outbound
    uint256 public retFace6; // cumulative face returned inbound (PRINCIPAL only — see completeInbound)
    uint256 public inFlight6; // sent, not yet acked as arrived on Arb
    uint256 public arbValue6; // keeper-attested Arb-side value
    uint256 public arbPrincipal6; // face value currently out (sent - returned)
    uint256 public syncTime; // last attestation timestamp
    uint256 public pendingRecall6; // recall asked for more than idle
    // Yield-vs-principal attribution (audit F-attribution, ported from
    // DNCoreStrategy/HLEarnStrategy; see docs/SUSD3_CCTP_SLEEVE_YIELD_ATTRIBUTION_DESIGN_2026-10-05.md §5).
    uint256 public profitRealized6; // realized yield cash that landed via completeInbound (gross)
    uint256 public profitSwept6; // realized yield already swept to the vault via harvest()

    event BridgedOut(uint256 amount, uint256 maxFee);
    event InboundCompleted(uint256 received);
    event ArrivalAcked(uint256 amount);
    event ArbValueSynced(uint256 value6);
    event RecallPending(uint256 shortfall);
    event IdlePushed(uint256 amount);
    event ParamsSet(uint256 headroomBps, uint256 minBridgeUsd6);
    event Recalled(uint256 requested, uint256 returned);
    event ProfitRealized(uint256 amount);
    event ProfitSwept(uint256 amount);
    event ProfitReconciled(uint256 oldRealized, uint256 newRealized);
    /// @dev AUDIT F-5 (round 2): emitted when the vault this strategy is wired to
    /// does NOT implement `onStrategyReturn` (a legacy, non-upgradeable vault).
    /// The principal has been returned, but it stays an uncredited arrival until
    /// the vault is migrated — the operator/runbook must not treat F-5 as booked.
    event ReturnHookUnavailable(address vault, uint256 amount);

    error PT__AccountingInvariant();
    error PT__ExceedsPrincipalIdle();
    error PT__BelowSwept();

    modifier onlyKeeperOrOwner() {
        require(msg.sender == owner() || msg.sender == keeper, "PT: not keeper");
        _;
    }

    constructor(
        address _underlying,
        address initialOwner,
        address _tokenMessenger,
        address _messageTransmitter,
        address _arbExecutor,
        uint32 _destDomain
    ) BaseStrategy(_underlying, initialOwner, "PendlePT") {
        require(
            _tokenMessenger != address(0) && _messageTransmitter != address(0) && _arbExecutor != address(0),
            "PT: zero addr"
        );
        // NOTE: no `!= 0` sentinel on _destDomain — CCTP domain 0 is VALID
        // (it is Ethereum). The original guard (an Arb-lane assumption) made
        // the ETH lane impossible: its constructor reverted "PT: zero domain"
        // on 2026-09-30. The domain is fixed at deploy and reviewed per lane.
        tokenMessenger = ITokenMessengerV2Burn(_tokenMessenger);
        messageTransmitter = IMessageTransmitterV2Recv(_messageTransmitter);
        arbExecutor = _arbExecutor;
        destDomain = _destDomain;
    }

    function name() external view override returns (string memory) {
        return "PendlePT";
    }

    // ---------------------------------------------------------------- keeper

    /// @notice Send idle USDC to the Arb executor via CCTP (fast transfer).
    /// PRINCIPAL ONLY (R-1): capped at `idlePrincipal6()` exactly like
    /// `pushIdle`/`recall`, so the keeper can never bridge the un-swept realized
    /// yield — the vault's `harvest()` owns that cash. Fee-free today (verified
    /// via Circle's fee API); `maxFee` is still capped so a fee change can never
    /// silently overcharge, and the burn reverts if the live fee exceeds it
    /// (Circle enforces maxFee on-chain).
    function deployToArb(uint256 amount, uint256 maxFee) external onlyKeeperOrOwner nonReentrant {
        require(isActive, "PT: inactive");
        require(amount >= minBridgeUsd6, "PT: below min bridge");
        require(maxFee <= MAX_BURN_FEE6, "PT: maxFee too high");
        uint256 bal = underlying.balanceOf(address(this));
        require(amount <= bal, "PT: exceeds idle");
        // R-1 (High): PRINCIPAL ONLY — mirror pushIdle/recall. `idlePrincipal6()`
        // = balance − harvestableProfit6(), so the un-swept realized yield can
        // never leave through this door. Without the cap, yield counted by
        // `profitRealized6` could be bridged out and never return; a venue loss
        // on that slice then let `vault.harvest()` sweep PRINCIPAL as yield and
        // permanently inflate `_totalAssets` above real backing (INV-1 breach).
        if (amount > idlePrincipal6()) revert PT__ExceedsPrincipalIdle();
        underlying.forceApprove(address(tokenMessenger), amount);
        // AUDIT F-A (deploy leg): pin `destinationCaller` to the SAME immutable
        // executor already used as the mint recipient, so only OUR executor can
        // complete this arrival — and only through its `relayArrival` entry point
        // (ops, or the 2/3 Safe as the recovery path). Ruling + threat model:
        // docs/F_A_DEPLOY_LEG_RULING_2026-10-17.md §2/§3.1/§4. Recipient and
        // permitted completer are one expression, so they can never disagree and
        // there is no new constructor argument to get wrong.
        // HARD RULE: never ship this pin without `relayArrival` in the executor
        // bytecode — the pin alone deadlocks the arrival (§4). The current
        // deployed executors have no relay and are NOT redeployed by this change;
        // this pin only ever runs on a fresh pair built with the relay.
        tokenMessenger.depositForBurn(
            amount,
            destDomain,
            bytes32(uint256(uint160(arbExecutor))),
            address(underlying),
            bytes32(uint256(uint160(arbExecutor))),
            maxFee,
            1000
        );
        sentFace6 += amount;
        inFlight6 += amount;
        arbPrincipal6 = sentFace6 - retFace6;
        emit BridgedOut(amount, maxFee);
    }

    /// @notice Complete a CCTP inbound transfer with the Circle attestation.
    /// Permissionless BY DESIGN: the mint can only land on THIS contract (the
    /// mintRecipient fixed in our return transfers), so anyone completing the
    /// transfer is doing us a favor. The keeper calls it in practice.
    function completeInbound(bytes calldata message, bytes calldata attestation)
        external
        nonReentrant
        returns (uint256 received)
    {
        uint256 balBefore = underlying.balanceOf(address(this));
        bool ok = messageTransmitter.receiveMessage(message, attestation);
        require(ok, "PT: receive failed");
        received = underlying.balanceOf(address(this)) - balBefore;
        require(received > 0, "PT: nothing minted");

        // YIELD/PRINCIPAL SPLIT (face-based, attestation-free): an inbound mint
        // retires outstanding PRINCIPAL first; any excess is realized YIELD.
        // Conservative by design — a partial unwind that in fact carried yield
        // but returns <= outstanding books as principal and defers the yield to
        // a later arrival (under-crediting is the safe direction: a credit can
        // never break INV-1).
        uint256 outstandingBefore = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        uint256 principalRed = received < outstandingBefore ? received : outstandingBefore;
        uint256 profitRed = received - principalRed;

        retFace6 += principalRed; // ONLY principal retires deployed face
        profitRealized6 += profitRed; // the only place yield is created on-chain
        // AUDIT F-1: an inbound mint is ALWAYS return-leg money, so it retires
        // the corresponding in-flight slice here. Previously inFlight6 was only
        // cleared by a separate keeper `ackArrival()`; a forgotten ack left the
        // returned cash counted TWICE (idle + still-"in-flight"), so the sleeve
        // reported up to 2x its real totalAssets() — the phantom pinned on
        // sUSD3. Consuming it makes arrival a single event; the ack is optional.
        // Capped so the counter can never underflow (a donation mint books
        // retFace without a matching send).
        inFlight6 = inFlight6 > received ? inFlight6 - received : 0;
        arbPrincipal6 = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        // The returned face is now idle cash; drop it from the attested value
        // (never double-count). The executor's value fell by the WHOLE bridged
        // amount regardless of the principal/yield split, so this stays
        // `received`. Keeper re-syncs the true remainder next poke.
        arbValue6 = arbValue6 > received ? arbValue6 - received : 0;
        emit InboundCompleted(received);
        if (profitRed > 0) emit ProfitRealized(profitRed);
    }

    /// @notice Keeper: acknowledge that `amount` of in-flight funds arrived on
    /// Arbitrum (observed via the executor's balance / Circle attestation).
    function ackArrival(uint256 amount) external onlyKeeperOrOwner nonReentrant {
        require(amount <= inFlight6, "PT: exceeds inFlight");
        inFlight6 -= amount;
        emit ArrivalAcked(amount);
    }

    /// @notice Keeper: attest the Arb-side value (PT position + Arb idle USDC).
    /// Bound: value <= arrivedFace x (1 + headroom). arrivedFace excludes the
    /// not-yet-acked in-flight slice (that part is already counted at face).
    function syncArbValue(uint256 value6) external onlyKeeperOrOwner nonReentrant {
        uint256 outstanding = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        // AUDIT F-1 (belt-and-braces): in-flight can never exceed what is still
        // out (sent - returned). If it does, the books are inconsistent — fail
        // loudly instead of silently flooring `arrivedFace` to 0 and masking a
        // phantom. completeInbound now consumes inFlight, so this can only trip
        // on a genuine logic error.
        if (inFlight6 > outstanding) revert PT__AccountingInvariant();
        uint256 arrivedFace = outstanding - inFlight6;
        uint256 cap = (arrivedFace * (10000 + headroomBps)) / 10000;
        require(value6 <= cap, "PT: value above bound");
        arbValue6 = value6;
        arbPrincipal6 = outstanding;
        syncTime = block.timestamp;
        emit ArbValueSynced(value6);
    }

    /// @notice Keeper: push idle USDC back to the vault (after an unwind lands).
    /// PRINCIPAL ONLY: `idlePrincipal6 = balance - harvestableProfit6`, so this
    /// door can never move the un-swept yield (that is `harvest()`'s door).
    /// BACKWARD-SAFE F-5: the transfer goes FIRST (the money comes home
    /// regardless), then the vault's return hook is a best-effort notification.
    /// The LIVE vault is non-upgradeable and PREDATES `onStrategyReturn`, so an
    /// unconditional call there reverts — which would roll the transfer back and
    /// brick the whole return path (the round-2 regression). A hook-less vault
    /// reverts the call, which we catch and surface as `ReturnHookUnavailable`.
    function pushIdle(uint256 amount) external onlyKeeperOrOwner nonReentrant {
        uint256 bal = underlying.balanceOf(address(this));
        if (amount > bal) amount = bal;
        require(amount > 0, "PT: nothing idle");
        if (amount > idlePrincipal6()) revert PT__ExceedsPrincipalIdle();
        underlying.safeTransfer(vault, amount);
        try IVaultReturnHook(vault).onStrategyReturn(amount) {
            // booked as redeployable accounted cash, totalAssets unchanged (F-5)
        } catch {
            emit ReturnHookUnavailable(vault, amount);
        }
        pendingRecall6 = pendingRecall6 > amount ? pendingRecall6 - amount : 0;
        emit IdlePushed(amount);
    }

    // ----------------------------------------------------------------- vault

    /// @notice Vault-only: pay what is idle; record the shortfall for the keeper.
    /// The Arb leg is asynchronous (sell PT -> CCTP standard ~15 min -> land),
    /// so a shortfall is EXPECTED during unwinds and covered by the vault's
    /// liquid reserve (_recallShortfall measures what actually arrived).
    /// Capped at `idlePrincipal6()`: a recall must never pay out the un-swept
    /// yield, which would land in the vault OUTSIDE `harvest()` (treated as an
    /// arrival) and, during a withdrawal, pay ONE user the yield that belongs to
    /// all depositors. Ops: harvest before a recall larger than the reserve.
    function recall(uint256 amount) external override nonReentrant {
        require(msg.sender == vault, "PT: not vault");
        if (amount == 0) return;
        uint256 idle = idlePrincipal6();
        uint256 sent = amount > idle ? idle : amount;
        if (sent > 0) underlying.safeTransfer(vault, sent);
        uint256 shortfall = amount - sent;
        if (shortfall > 0) {
            pendingRecall6 += shortfall;
            emit RecallPending(shortfall);
        }
        emit Recalled(amount, sent);
    }

    // ----------------------------------------------------------------- views

    function outstandingFace6() public view returns (uint256) {
        return sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
    }

    function totalAssets() public view override returns (uint256) {
        return underlying.balanceOf(address(this)) + inFlight6 + arbValue6;
    }

    /// @notice Realized yield still waiting to be swept to the vault.
    function harvestableProfit6() public view returns (uint256) {
        return profitRealized6 > profitSwept6 ? profitRealized6 - profitSwept6 : 0;
    }

    /// @notice Principal the sleeve currently holds on the vault's behalf (idle,
    /// undeployed, or freshly returned), i.e. EVERYTHING except the still-unswept
    /// realized yield. Derived, not tracked — stays correct across vault
    /// allocations (unobserved), deployToArb, completeInbound, pushIdle and
    /// recall without any new vault hook. Donations and
    /// freshly-allocated-but-not-yet-bridged cash are all returnable as principal,
    /// none of it is yield.
    function idlePrincipal6() public view returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        uint256 hp = harvestableProfit6();
        return bal > hp ? bal - hp : 0;
    }

    // ---------------------------------------------------------------- harvest

    /// @dev Vault-only sweep of realized yield (mirrors DNCoreStrategy /
    /// HLEarnStrategy). A keeper/owner call only settles (returns 0); the VAULT's
    /// call transfers exactly `harvestableProfit6()` so the vault's own
    /// balance-delta is the crediting measurement — no new vault code. Gating to
    /// the vault is mandatory: a keeper/owner direct sweep would land the yield
    /// at the vault OUTSIDE `harvest()` and re-create an uncredited arrival.
    function _doHarvest() internal override returns (uint256 profit) {
        require(msg.sender == owner() || msg.sender == keeper || msg.sender == vault, "PT: not keeper");
        if (msg.sender != vault) return 0; // keeper/owner settle only; VAULT sweeps
        uint256 sweep = harvestableProfit6();
        if (sweep == 0) return 0;
        // harvestableProfit6() <= balance by construction (idlePrincipal6 >= 0),
        // belt-and-braces: never ship more cash than we hold.
        if (sweep > underlying.balanceOf(address(this))) return 0;
        profitSwept6 += sweep;
        underlying.safeTransfer(vault, sweep);
        emit ProfitSwept(sweep);
        return sweep;
    }

    // ----------------------------------------------------------------- owner

    /// @notice Owner-only bookkeeping reconciliation for `profitRealized6`.
    /// Funds-safe: it only sizes future sweeps and can never be set below what
    /// has already been swept, so a bad reconcile can strand credit but can never
    /// claw back cash the vault already holds. Needed because a
    /// duplicated/dropped bridge or a donation-mint can misstate the counter —
    /// the same hatch DNCoreStrategy/HLEarnStrategy shipped.
    ///
    /// R-3 (documented owner-trust surface, not a hard bound): there is NO UPPER
    /// BOUND. Raising `profitRealized6` above the real idle cash raises
    /// `harvestableProfit6()` too, so a subsequent vault `harvest()` could sweep
    /// PRINCIPAL as yield — i.e. this is a second principal-as-yield route,
    /// reachable only by the OWNER. It is left open deliberately: the owner is
    /// already trusted with the vault's mint/param surface, and a hard cap would
    /// defeat the hatch's purpose (reconciling a counter that is transiently
    /// mis-stated relative to cash). Mitigations are operational: treat
    /// `reconcileProfit` as a break-glass call, log the `ProfitReconciled` event,
    /// and confirm `harvestableProfit6() <= balanceOf(this)` after any reconcile.
    /// (`deployToArb`/`pushIdle`/`recall` are capped at `idlePrincipal6()`, so an
    /// inflated counter also freezes principal movement until it is reconciled
    /// back — fail-closed, but callable only by the owner.)
    function reconcileProfit(uint256 newRealized) external onlyOwner {
        if (newRealized < profitSwept6) revert PT__BelowSwept();
        uint256 old = profitRealized6;
        profitRealized6 = newRealized;
        emit ProfitReconciled(old, newRealized);
    }

    function setParams(uint256 _headroomBps, uint256 _minBridgeUsd6) external onlyOwner nonReentrant {
        require(_headroomBps <= MAX_HEADROOM_BPS, "PT: headroom too high");
        require(_minBridgeUsd6 >= 2e6, "PT: min too low");
        headroomBps = _headroomBps;
        minBridgeUsd6 = _minBridgeUsd6;
        emit ParamsSet(_headroomBps, _minBridgeUsd6);
    }
}
