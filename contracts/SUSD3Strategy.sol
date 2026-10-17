// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FrontierBase} from "./FrontierBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITokenMessengerV2BurnSusd {
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

interface IMessageTransmitterV2RecvSusd {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}

/// @notice The vault hook that books a strategy's returned PRINCIPAL without
/// crediting it as yield (audit F-5). See ProYieldVault.onStrategyReturn.
interface IVaultReturnHook {
    function onStrategyReturn(uint256 amount) external;
}

/// @notice Frontier sUSD3 junior-tranche sleeve — HyperEVM side (vault-facing).
///
/// Architecture (mirrors the proven PTSleeveStrategy exactly; the venue is
/// 3Jane's sUSD3 junior tranche on Ethereum mainnet — see
/// docs/CREDIT_POOL_DD.md):
///   vault (HyperEVM) -> THIS contract holds USDC ->
///   CCTP burn (fee-free, domain 0 = Ethereum) -> SUSD3Executor on mainnet
///   wraps USDC → USD3 → sUSD3 (junior/first-loss tranche), drives the
///   venue's async cooldown lifecycle on the way out, and returns USDC via
///   the reverse CCTP path.
///
/// Accounting model (identical to the PT sleeve, all USDC 6dp):
///   totalAssets = idle + inFlight6 + ethValue6
///   - `sentFace6`/`retFace6`: monotonic cumulative face flows (CCTP mints 1:1).
///   - `inFlight6`: sent, not yet acked as arrived on mainnet.
///   - `ethValue6`: keeper-attested mainnet position value (sUSD3 → USD3 →
///     USDC double-hop mark + executor idle), CLAMPED to arrived-face ×
///     (1 + headroom) on every sync — the keeper can never inflate the book
///     beyond what actually left this contract.
///
/// FIRST-LOSS HONESTY (the delta vs the PT sleeve): sUSD3 can lose principal.
/// A downward sync is a REAL mark-down, never smoothed: `ethValue6` follows
/// the mark down and `LossObserved(oldValue, newValue)` fires so the
/// feed/attestation records it. totalAssets() reflects the loss immediately.
///
/// Trust model: the only money movements out of this contract are
/// (a) CCTP burns to the IMMUTABLE `ethExecutor`, and (b) transfers to the
/// vault. The keeper can poke and attest but cannot redirect a single cent.
/// The Frontier gate (venueCleared + ≤15% of the vault book) guards the
/// supply path (deployToEth); recall/bridge-back are never gated. The supply
/// path is PRINCIPAL-ONLY (R-1): `deployToEth`/`pushIdle`/`recall` are all
/// capped at `idlePrincipal6()` (= idle balance − `harvestableProfit6()`), so
/// the un-swept realized yield can leave ONLY through the vault's `harvest()`.
contract SUSD3Strategy is FrontierBase {
    using SafeERC20 for IERC20;

    ITokenMessengerV2BurnSusd public immutable tokenMessenger;
    IMessageTransmitterV2RecvSusd public immutable messageTransmitter;
    address public immutable ethExecutor; // CCTP mint target on Ethereum (immutable)
    uint32 public constant DEST_DOMAIN = 0; // CCTP domain 0 = Ethereum

    uint256 public constant MAX_HEADROOM_BPS = 3000; // hard cap: +30%
    uint256 public headroomBps = 2000; // default attestation headroom: +20%
    uint256 public minBridgeUsd6 = 5e6; // never bridge dust ($5)
    uint256 public constant MAX_BURN_FEE6 = 2e6; // keeper maxFee arg cap ($2)

    uint256 public sentFace6; // cumulative face sent outbound
    uint256 public retFace6; // cumulative face returned inbound
    uint256 public inFlight6; // sent, not yet acked as arrived on mainnet
    uint256 public ethValue6; // keeper-attested mainnet position value
    uint256 public ethPrincipal6; // face value currently out (sent - returned)
    uint256 public syncTime; // last attestation timestamp
    uint256 public pendingRecall6; // recall asked for more than idle
    // Yield-vs-principal attribution (design note §5, ported from
    // DNCoreStrategy/HLEarnStrategy; see
    // docs/SUSD3_CCTP_SLEEVE_YIELD_ATTRIBUTION_DESIGN_2026-10-05.md §5).
    uint256 public profitRealized6; // realized yield cash that landed via completeInbound (gross)
    uint256 public profitSwept6; // realized yield already swept to the vault via harvest()

    event BridgedOut(uint256 amount, uint256 maxFee);
    event InboundCompleted(uint256 received);
    event ArrivalAcked(uint256 amount);
    event EthValueSynced(uint256 value6);
    event LossObserved(uint256 oldValue6, uint256 newValue6);
    event RecallPending(uint256 shortfall);
    event IdlePushed(uint256 amount);
    /// @dev AUDIT F-5 (review round 2): emitted when the vault this strategy is
    /// wired to does NOT implement `onStrategyReturn` (a legacy, non-upgradeable
    /// vault). The principal has been returned, but it stays an uncredited
    /// arrival until the vault is migrated — the operator/runbook must not treat
    /// F-5 as booked.
    event ReturnHookUnavailable(address vault, uint256 amount);
    event ParamsSet(uint256 headroomBps, uint256 minBridgeUsd6);
    event Recalled(uint256 requested, uint256 returned);
    event ProfitRealized(uint256 amount);
    event ProfitSwept(uint256 amount);
    event ProfitReconciled(uint256 oldRealized, uint256 newRealized);

    error SUSD3__NotKeeper();
    error SUSD3__Inactive();
    error SUSD3__NotVault();
    error SUSD3__BelowMinBridge();
    error SUSD3__MaxFeeTooHigh();
    error SUSD3__ExceedsIdle();
    error SUSD3__ExceedsInFlight();
    error SUSD3__ValueAboveBound();
    error SUSD3__NothingIdle();
    error SUSD3__ReceiveFailed();
    error SUSD3__NothingMinted();
    error SUSD3__ZeroAddr();
    error SUSD3__AccountingInvariant();
    error SUSD3__ExceedsPrincipalIdle();
    error SUSD3__BelowSwept();

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && msg.sender != keeper) revert SUSD3__NotKeeper();
        _;
    }

    constructor(
        address _underlying,
        address initialOwner,
        address _tokenMessenger,
        address _messageTransmitter,
        address _ethExecutor
    ) FrontierBase(_underlying, initialOwner, "SUSD3") {
        if (_tokenMessenger == address(0) || _messageTransmitter == address(0) || _ethExecutor == address(0)) {
            revert SUSD3__ZeroAddr();
        }
        tokenMessenger = ITokenMessengerV2BurnSusd(_tokenMessenger);
        messageTransmitter = IMessageTransmitterV2RecvSusd(_messageTransmitter);
        ethExecutor = _ethExecutor;
    }

    function name() external pure override returns (string memory) {
        return "SUSD3";
    }

    // ---------------------------------------------------------------- keeper

    /// @notice Send idle USDC to the Ethereum executor via CCTP (fast burn).
    /// GATED: requires venueCleared (per-name DD) and the ≤15% per-name cap,
    /// checked BEFORE any token moves — the Frontier supply path.
    /// PRINCIPAL ONLY (R-1): capped at `idlePrincipal6()` exactly like
    /// `pushIdle`/`recall`, so the keeper can never bridge the un-swept realized
    /// yield — the vault's `harvest()` owns that cash.
    function deployToEth(uint256 amount, uint256 maxFee) external onlyKeeperOrOwner nonReentrant {
        if (!isActive) revert SUSD3__Inactive();
        if (amount < minBridgeUsd6) revert SUSD3__BelowMinBridge();
        if (maxFee > MAX_BURN_FEE6) revert SUSD3__MaxFeeTooHigh();
        _frontierGate(); // reverts NotCleared / CapExceeded / CapUnverifiable
        uint256 bal = underlying.balanceOf(address(this));
        if (amount > bal) revert SUSD3__ExceedsIdle();
        // R-1 (High, pre-deploy review t_1ecae5f9): PRINCIPAL ONLY — mirror
        // pushIdle/recall. `idlePrincipal6()` = balance − harvestableProfit6(),
        // so the un-swept realized yield can never leave through this door.
        // Without the cap, yield counted by `profitRealized6` could be bridged
        // out and never return; a venue loss on that slice then let
        // `vault.harvest()` sweep PRINCIPAL as yield and permanently inflate
        // `_totalAssets` above real backing (INV-1 breach). This is the same
        // class PT fixed in `deployToArb` (t_72645efe).
        if (amount > idlePrincipal6()) revert SUSD3__ExceedsPrincipalIdle();
        underlying.forceApprove(address(tokenMessenger), amount);
        // AUDIT F-A (deploy leg): pin `destinationCaller` to the SAME immutable
        // executor already used as the mint recipient — only OUR executor can
        // complete the arrival, and only through its `relayArrival` entry point
        // (ops, or the 2/3 Safe as the recovery path). Ruling + threat model:
        // docs/F_A_DEPLOY_LEG_RULING_2026-10-17.md §2/§3.1/§4.
        // HARD RULE: never ship this pin without `relayArrival` in the executor
        // bytecode — the pin alone deadlocks the arrival (§4).
        tokenMessenger.depositForBurn(
            amount,
            DEST_DOMAIN,
            bytes32(uint256(uint160(ethExecutor))),
            address(underlying),
            bytes32(uint256(uint160(ethExecutor))),
            maxFee,
            1000
        );
        sentFace6 += amount;
        inFlight6 += amount;
        ethPrincipal6 = sentFace6 - retFace6;
        emit BridgedOut(amount, maxFee);
    }

    /// @notice Complete a CCTP inbound transfer with the Circle attestation.
    /// Permissionless BY DESIGN: the mint can only land on THIS contract.
    function completeInbound(bytes calldata message, bytes calldata attestation)
        external
        nonReentrant
        returns (uint256 received)
    {
        uint256 balBefore = underlying.balanceOf(address(this));
        bool ok = messageTransmitter.receiveMessage(message, attestation);
        if (!ok) revert SUSD3__ReceiveFailed();
        received = underlying.balanceOf(address(this)) - balBefore;
        if (received == 0) revert SUSD3__NothingMinted();

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
        // cleared by a separate keeper `ackArrival`; a forgotten ack left the
        // returned cash counted TWICE (idle + still-"in-flight"). Consuming it
        // makes arrival a single event and the ack step optional. Capped so the
        // counter can never underflow (a donation mint books retFace without a
        // matching send).
        inFlight6 = inFlight6 > received ? inFlight6 - received : 0;
        ethPrincipal6 = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        // The returned face is now idle cash; drop it from the attested value
        // (never double-count). The executor's value fell by the WHOLE bridged
        // amount regardless of the principal/yield split, so this stays
        // `received`. Keeper re-syncs the true remainder next poke.
        ethValue6 = ethValue6 > received ? ethValue6 - received : 0;
        emit InboundCompleted(received);
        if (profitRed > 0) emit ProfitRealized(profitRed);
    }

    /// @notice Keeper: acknowledge that `amount` of in-flight funds arrived
    /// on mainnet (observed via the executor's balance / Circle attestation).
    function ackArrival(uint256 amount) external onlyKeeperOrOwner nonReentrant {
        if (amount > inFlight6) revert SUSD3__ExceedsInFlight();
        inFlight6 -= amount;
        emit ArrivalAcked(amount);
    }

    /// @notice Keeper: attest the mainnet position value (executor idle USDC
    /// + the sUSD3 → USD3 → USDC double-hop mark).
    /// Bound: value <= arrivedFace × (1 + headroom) — the upside is clamped.
    /// The DOWNSIDE is never clamped: a lower mark is recorded as-is and
    /// surfaces as LossObserved (first-loss honesty).
    function syncEthValue(uint256 value6) external onlyKeeperOrOwner nonReentrant {
        uint256 outstanding = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        // AUDIT F-1 (belt-and-braces): in-flight can never exceed what is still
        // out (sent - returned). If it does, the books are inconsistent — fail
        // loudly instead of silently flooring `arrivedFace` to 0 and masking a
        // phantom. completeInbound now consumes inFlight, so this can only trip
        // on a genuine logic error.
        if (inFlight6 > outstanding) revert SUSD3__AccountingInvariant();
        uint256 arrivedFace = outstanding > inFlight6 ? outstanding - inFlight6 : 0;
        uint256 cap = (arrivedFace * (10000 + headroomBps)) / 10000;
        if (value6 > cap) revert SUSD3__ValueAboveBound();
        uint256 old = ethValue6;
        ethValue6 = value6;
        ethPrincipal6 = outstanding;
        syncTime = block.timestamp;
        emit EthValueSynced(value6);
        if (value6 < old) emit LossObserved(old, value6);
    }

    /// @notice Keeper: push idle USDC back to the vault (after a return lands).
    /// AUDIT F-5: the transfer is followed by the vault's return hook so the
    /// returned PRINCIPAL is booked as accounted cash — redeployable by the
    /// next `allocate()` — WITHOUT raising the vault's `_totalAssets` (which
    /// would double-count it). A bare transfer used to land as an uncredited
    /// arrival: allocatable never, and creditable only via `creditYield`, which
    /// would inflate the share price.
    ///
    /// BACKWARD-SAFE (review round 2): the hook exists only on vaults that carry
    /// `ProYieldVault.onStrategyReturn`. The LIVE vault `0x8954…D1C1` is
    /// non-upgradeable and PREDATES it, so an unconditional call there reverts —
    /// which would roll the transfer back and brick the whole return path (the
    /// regression the reviewer caught). So the transfer goes first (the money
    /// comes home regardless), and the hook is a best-effort notification: a
    /// hook-less vault reverts the call, which we catch and surface as
    /// `ReturnHookUnavailable`. A hook-bearing vault books the principal as
    /// accounted cash with no `_totalAssets` change.
    ///
    /// PRINCIPAL ONLY (design note §5): `idlePrincipal6 = balance −
    /// harvestableProfit6`, so this door can never move the un-swept yield (that
    /// is `harvest()`'s door — a keeper asking for more than the principal
    /// reverts `SUSD3__ExceedsPrincipalIdle`).
    function pushIdle(uint256 amount) external onlyKeeperOrOwner nonReentrant {
        uint256 bal = underlying.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) revert SUSD3__NothingIdle();
        if (amount > idlePrincipal6()) revert SUSD3__ExceedsPrincipalIdle();
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

    /// @notice Vault-only: pay what is idle; record the shortfall for the
    /// keeper. The mainnet leg is asynchronous BY VENUE DESIGN (30-day
    /// cooldown before shares become redeemable), so a shortfall is EXPECTED
    /// during unwinds and covered by the vault's liquid reserve.
    /// Capped at `idlePrincipal6()` (design note §5): a recall must never pay
    /// out the un-swept yield — that would land in the vault OUTSIDE `harvest()`
    /// (treated as an arrival) and, during a withdrawal, pay ONE user the yield
    /// that belongs to all depositors. Ops: harvest before a recall larger than
    /// the vault's reserve (a harvest also ADDS the yield to vault liquidity).
    function recall(uint256 amount) external override nonReentrant {
        if (msg.sender != vault) revert SUSD3__NotVault();
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
        return underlying.balanceOf(address(this)) + inFlight6 + ethValue6;
    }

    /// @notice Realized yield still waiting to be swept to the vault.
    function harvestableProfit6() public view returns (uint256) {
        return profitRealized6 > profitSwept6 ? profitRealized6 - profitSwept6 : 0;
    }

    /// @notice Principal the sleeve currently holds on the vault's behalf (idle,
    /// undeployed, or freshly returned), i.e. EVERYTHING except the still-unswept
    /// realized yield. Derived, not tracked — stays correct across vault
    /// allocations (unobserved), deployToEth, completeInbound, pushIdle and
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
    /// HLEarnStrategy and the PT sleeve). A keeper/owner call only settles
    /// (returns 0); the VAULT's call transfers exactly `harvestableProfit6()` so
    /// the vault's own balance-delta is the crediting measurement — no new vault
    /// code. Gating to the vault is mandatory: a keeper/owner direct sweep would
    /// land the yield at the vault OUTSIDE `harvest()` and re-create an
    /// uncredited arrival.
    function _doHarvest() internal override returns (uint256 profit) {
        if (msg.sender != owner() && msg.sender != keeper && msg.sender != vault) revert SUSD3__NotKeeper();
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
    /// (`deployToEth`/`pushIdle`/`recall` are capped at `idlePrincipal6()`, so an
    /// inflated counter also freezes principal movement until it is reconciled
    /// back — fail-closed, but callable only by the owner.)
    function reconcileProfit(uint256 newRealized) external onlyOwner {
        if (newRealized < profitSwept6) revert SUSD3__BelowSwept();
        uint256 old = profitRealized6;
        profitRealized6 = newRealized;
        emit ProfitReconciled(old, newRealized);
    }

    function setParams(uint256 _headroomBps, uint256 _minBridgeUsd6) external onlyOwner nonReentrant {
        require(_headroomBps <= MAX_HEADROOM_BPS, "SUSD3: headroom too high");
        require(_minBridgeUsd6 >= 2e6, "SUSD3: min too low");
        headroomBps = _headroomBps;
        minBridgeUsd6 = _minBridgeUsd6;
        emit ParamsSet(_headroomBps, _minBridgeUsd6);
    }
}
