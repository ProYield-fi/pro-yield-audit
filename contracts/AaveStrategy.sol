// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FrontierBase} from "./FrontierBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITokenMessengerV2BurnAave {
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

interface IMessageTransmitterV2RecvAave {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}

/// @notice The vault hook that books a strategy's returned PRINCIPAL without
/// crediting it as yield (audit F-5). See ProYieldVault.onStrategyReturn.
interface IVaultReturnHookAave {
    function onStrategyReturn(uint256 amount) external;
}

/// @notice Frontier Aave v4 USDC Tokenization-Spoke sleeve — HyperEVM side
/// (vault-facing). Sibling of `SUSD3Strategy` / `PTSleeveStrategy`; the venue
/// difference is the EXIT SHAPE, not this contract.
///
/// Architecture (mirrors the proven cross-chain seam exactly):
///   vault (HyperEVM) -> THIS contract holds USDC ->
///   CCTP burn (domain 0 = Ethereum) -> `AaveExecutor` on Ethereum mainnet
///   deposits USDC into the Aave v4 USDC **Tokenization Spoke** (ERC-4626,
///   waPrimeUSDC `0x486415fb…Cb31`) and redeems out of it, returning USDC via
///   the reverse CCTP path.
///
/// WHY THE VENUE WRAP LIVES ON ETHEREUM, NOT HERE: the Aave v4 hub/spoke
/// deployment is Ethereum-mainnet (`docs/AAVE_DD.md` §4 "Chain fit"). A
/// HyperEVM contract cannot call an Ethereum contract, so the ERC-4626 wrap is
/// `contracts/ethi/AaveExecutor.sol`; THIS contract is the only counterparty
/// that can sit in a HyperEVM vault's `strategyList` and the only one that can
/// carry the Frontier gate (`setVenueCleared` + the ≤15% per-name cap).
///
/// Accounting model (identical to the PT / sUSD3 sleeves, all USDC 6dp):
///   totalAssets = idle + inFlight6 + ethValue6
///   - `sentFace6`/`retFace6`: monotonic cumulative face flows (CCTP mints 1:1).
///     `retFace6` books returned PRINCIPAL only; `feesPaid6` is the cumulative
///     face retired at a position CLOSE that never came home (the CCTP
///     destination fee on the bridge legs / a shortfall realised at close), so
///     `outstandingFace6()` = `sentFace6 − retFace6 − feesPaid6` never carries a
///     permanent phantom (AUDIT F-D). The deploy/attest bound and
///     `completeInbound` keep working off the received-vs-sent face
///     (`sentFace6 − retFace6`), so a retirement can never change a later
///     return's principal/yield split nor lock the attestation bound.
///   - `inFlight6`: sent, not yet acked as arrived on mainnet.
///   - `ethValue6`: keeper-attested mainnet position value (executor idle USDC
///     + the waPrimeUSDC mark), CLAMPED to arrived-face × (1 + headroom) on
///     every sync — the keeper can never inflate the book beyond what actually
///     left this contract.
///
/// LIQUIDITY-CONDITIONAL EXIT (the venue's defining property — AAVE_DD §5):
/// the Tokenization Spoke's redeem is capped by the Hub's *un-borrowed* USDC at
/// that block, and is blocked outright by a spoke halt. There is NO forced
/// unwind anywhere in this lane: `recall` pays what is idle and records the
/// shortfall for the keeper to settle as the Hub refills. The recall monitor
/// quantity `pendingRecall6()` is an EXACT cumulative ledger (`recallDemand6`
/// minus `recallPaid6`) — a `recall` has no id, so the undecidable "re-request
/// vs fresh demand" split is removed rather than modelled (AUDIT F-C exact);
/// the executor's own exit is capped by `maxRedeem` and a partially-utilized
/// position simply unwinds in slices. `totalAssets()` follows the keeper's
/// attested mark DOWN as well as up (a lending deficit is a real mark-down and
/// fires `LossObserved` — never smoothed).
///
/// Trust model: the only money movements out of this contract are
/// (a) CCTP burns to the IMMUTABLE `ethExecutor`, and (b) transfers to the
/// vault. The keeper can poke and attest but cannot redirect a single cent.
/// The Frontier gate (venueCleared + ≤15% of the vault book) guards the supply
/// path (deployToEth); recall/bridge-back are never gated. The supply path is
/// PRINCIPAL-ONLY (R-1): `deployToEth`/`pushIdle`/`recall` are all capped at
/// `idlePrincipal6()` (= idle balance − `harvestableProfit6()`), so un-swept
/// realized yield can leave ONLY through the vault's `harvest()`.
contract AaveStrategy is FrontierBase {
    using SafeERC20 for IERC20;

    ITokenMessengerV2BurnAave public immutable tokenMessenger;
    IMessageTransmitterV2RecvAave public immutable messageTransmitter;
    address public immutable ethExecutor; // CCTP mint target on Ethereum (immutable)
    uint32 public constant DEST_DOMAIN = 0; // CCTP domain 0 = Ethereum

    uint256 public constant MAX_HEADROOM_BPS = 3000; // hard cap: +30%
    uint256 public headroomBps = 2000; // default attestation headroom: +20%
    uint256 public minBridgeUsd6 = 5e6; // never bridge dust ($5)
    uint256 public constant MAX_BURN_FEE6 = 2e6; // keeper maxFee arg cap ($2)

    uint256 public sentFace6; // cumulative face sent outbound (gross burned)
    uint256 public retFace6; // cumulative face RETIRED inbound (received cash principal ONLY)
    uint256 public inFlight6; // sent, not yet acked as arrived on mainnet
    uint256 public ethValue6; // keeper-attested mainnet position value
    uint256 public ethPrincipal6; // face value currently out (= sent - retired - feesPaid, floored)
    uint256 public syncTime; // last attestation timestamp
    // AUDIT F-D: cumulative face retired at a position CLOSE that never came home
    // as received principal — the CCTP destination fee on the bridge legs (and
    // any shortfall realised at close). Kept SEPARATE from `retFace6` so
    // `outstandingFace6()` carries no phantom while `retFace6` stays a pure
    // received-cash counter. Never feeds the deploy/attest bound or the
    // `completeInbound` principal/yield split (those stay on `sentFace6 -
    // retFace6`), so a retirement can never lock the bound or reclassify a
    // later return.
    uint256 public feesPaid6;
    // AUDIT F-D guard: the highest non-zero value attested since the last
    // `deployToEth` (the current deployment cycle). A retirement requires it,
    // so a first-ever / never-attested zero sync — the ack→sync (F-E) window at
    // the start of every cycle — can NEVER write off face. Reset to 0 by
    // `deployToEth` (new cycle) and after a retirement (cycle closed).
    uint256 public cyclePeak6;
    // AUDIT F-C (exact): the recall counter is a CUMULATIVE ledger, never a
    // modelled residual. `recall(amount)` carries no id, so the chain cannot
    // distinguish "the vault re-requests the deferred slice" from "a fresh,
    // independently-paid demand" — the ambiguity is removed instead of guessed:
    // every `recall` adds its full `amount` to `recallDemand6`; every payment
    // back to the vault (`recall` `sent`, or `pushIdle`) settles OUTSTANDING
    // demand ONLY (`recallPaid6` is capped at `recallDemand6`, so a payment made
    // when nothing is owed never banks a credit that could mask a later real
    // shortfall), and `pendingRecall6()` is the residual `demand - paid`
    // (floored). `pushIdle` is the settling action.
    uint256 public recallDemand6; // cumulative recall asked by the vault
    uint256 public recallPaid6; // cumulative principal returned to the vault (recall + pushIdle), <= recallDemand6
    uint256 public profitRealized6; // realized yield cash that landed via completeInbound (gross)
    uint256 public profitSwept6; // realized yield already swept to the vault via harvest()

    event BridgedOut(uint256 amount, uint256 maxFee);
    event InboundCompleted(uint256 received);
    event ArrivalAcked(uint256 amount);
    event EthValueSynced(uint256 value6);
    event LossObserved(uint256 oldValue6, uint256 newValue6);
    event RecallPending(uint256 shortfall);
    event IdlePushed(uint256 amount);
    /// @dev AUDIT F-D: face retired on a closed position that never returned as
    /// received principal (CCTP destination fee on the bridge legs / realised
    /// shortfall). Keeps `outstandingFace6()` exact instead of carrying a phantom.
    event FaceRetired(uint256 amount);
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

    error AAVE__NotKeeper();
    error AAVE__Inactive();
    error AAVE__NotVault();
    error AAVE__BelowMinBridge();
    error AAVE__MaxFeeTooHigh();
    error AAVE__ExceedsIdle();
    error AAVE__ExceedsInFlight();
    error AAVE__ValueAboveBound();
    error AAVE__NothingIdle();
    error AAVE__ReceiveFailed();
    error AAVE__NothingMinted();
    error AAVE__ZeroAddr();
    error AAVE__AccountingInvariant();
    error AAVE__ExceedsPrincipalIdle();
    error AAVE__BelowSwept();

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && msg.sender != keeper) revert AAVE__NotKeeper();
        _;
    }

    constructor(
        address _underlying,
        address initialOwner,
        address _tokenMessenger,
        address _messageTransmitter,
        address _ethExecutor
    ) FrontierBase(_underlying, initialOwner, "Aave") {
        if (_tokenMessenger == address(0) || _messageTransmitter == address(0) || _ethExecutor == address(0)) {
            revert AAVE__ZeroAddr();
        }
        tokenMessenger = ITokenMessengerV2BurnAave(_tokenMessenger);
        messageTransmitter = IMessageTransmitterV2RecvAave(_messageTransmitter);
        ethExecutor = _ethExecutor;
    }

    function name() external pure override returns (string memory) {
        return "Aave";
    }

    // ---------------------------------------------------------------- keeper

    /// @notice Send idle USDC to the Ethereum executor via CCTP (fast burn).
    /// GATED: requires venueCleared (per-name DD) and the ≤15% per-name cap,
    /// checked BEFORE any token moves — the Frontier supply path.
    /// PRINCIPAL ONLY (R-1): capped at `idlePrincipal6()` exactly like
    /// `pushIdle`/`recall`, so the keeper can never bridge the un-swept realized
    /// yield — the vault's `harvest()` owns that cash.
    function deployToEth(uint256 amount, uint256 maxFee) external onlyKeeperOrOwner nonReentrant {
        if (!isActive) revert AAVE__Inactive();
        if (amount < minBridgeUsd6) revert AAVE__BelowMinBridge();
        if (maxFee > MAX_BURN_FEE6) revert AAVE__MaxFeeTooHigh();
        _frontierGate(); // reverts NotCleared / CapExceeded / CapUnverifiable
        uint256 bal = underlying.balanceOf(address(this));
        if (amount > bal) revert AAVE__ExceedsIdle();
        if (amount > idlePrincipal6()) revert AAVE__ExceedsPrincipalIdle();
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
        ethPrincipal6 = outstandingFace6();
        cyclePeak6 = 0; // AUDIT F-D: a new deployment cycle begins — the open→closed evidence resets
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
        if (!ok) revert AAVE__ReceiveFailed();
        received = underlying.balanceOf(address(this)) - balBefore;
        if (received == 0) revert AAVE__NothingMinted();

        // YIELD/PRINCIPAL SPLIT (face-based, attestation-free): an inbound mint
        // retires outstanding PRINCIPAL first; any excess is realized YIELD.
        // Conservative by design — a partial unwind that in fact carried yield
        // but returns <= outstanding books as principal and defers the yield to
        // a later arrival (under-crediting is the safe direction).
        uint256 outstandingBefore = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        uint256 principalRed = received < outstandingBefore ? received : outstandingBefore;
        uint256 profitRed = received - principalRed;

        retFace6 += principalRed; // ONLY principal retires deployed face
        profitRealized6 += profitRed; // the only place yield is created on-chain
        // AUDIT F-1: an inbound mint is ALWAYS return-leg money, so it retires
        // the corresponding in-flight slice here (a forgotten ack used to leave
        // the returned cash counted TWICE: idle + still-"in-flight").
        inFlight6 = inFlight6 > received ? inFlight6 - received : 0;
        ethPrincipal6 = outstandingFace6();
        // The returned face is now idle cash; drop it from the attested value
        // (never double-count). The executor's value fell by the WHOLE bridged
        // amount regardless of the principal/yield split.
        ethValue6 = ethValue6 > received ? ethValue6 - received : 0;
        emit InboundCompleted(received);
        if (profitRed > 0) emit ProfitRealized(profitRed);
    }

    /// @notice Keeper: acknowledge that `amount` of in-flight funds arrived
    /// on mainnet (observed via the executor's balance / Circle attestation).
    function ackArrival(uint256 amount) external onlyKeeperOrOwner nonReentrant {
        if (amount > inFlight6) revert AAVE__ExceedsInFlight();
        inFlight6 -= amount;
        emit ArrivalAcked(amount);
    }

    /// @notice Keeper: attest the mainnet position value (executor idle USDC
    /// + the waPrimeUSDC ERC-4626 mark).
    /// Bound: value <= arrivedFace × (1 + headroom) — the upside is clamped.
    /// The DOWNSIDE is never clamped: a lower mark is recorded as-is and
    /// surfaces as LossObserved (a lending deficit is a real mark-down).
    function syncEthValue(uint256 value6) external onlyKeeperOrOwner nonReentrant {
        // The deploy/attest bound works off the RECEIVED-vs-SENT face (gross),
        // NOT `outstandingFace6()` — so a prior F-D retirement can never lock
        // the bound and a truthful re-attestation is always accepted.
        uint256 grossOut = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        // AUDIT F-1 (belt-and-braces): in-flight can never exceed what is still
        // out (sent - returned) — fail loudly instead of silently flooring
        // `arrivedFace` to 0 and masking a phantom.
        if (inFlight6 > grossOut) revert AAVE__AccountingInvariant();
        uint256 arrivedFace = grossOut > inFlight6 ? grossOut - inFlight6 : 0;
        uint256 cap = (arrivedFace * (10000 + headroomBps)) / 10000;
        if (value6 > cap) revert AAVE__ValueAboveBound();
        uint256 old = ethValue6;
        ethValue6 = value6;
        syncTime = block.timestamp;
        emit EthValueSynced(value6);
        if (value6 < old) emit LossObserved(old, value6);
        // Track the cycle's high-water mark: the position counts as "was open"
        // only once a NON-ZERO value has been attested since the last deploy.
        if (value6 > cyclePeak6) cyclePeak6 = value6;
        // AUDIT F-D: retire the residual face ONLY on evidence of a genuine
        // OPEN→CLOSED transition — a ZERO attestation, nothing in flight, AND
        // the position was attested non-zero earlier in THIS deployment cycle
        // (`cyclePeak6 > 0`). The trigger is a KEEPER ATTESTATION, not a
        // verified close: a stale/pre-deposit read of 0, or any zero sync in the
        // ack→sync (F-E) window that starts every cycle, must never write off
        // face, so the close routine must read BOTH the executor's idle USDC and
        // the spoke mark as zero before calling this with 0.
        // Any face still booked out then can never return — the CCTP destination
        // fee on the bridge legs (or a shortfall realised at close) — so RETIRE
        // it into `feesPaid6` (its own counter; `retFace6` stays received cash),
        // leaving `outstandingFace6()` exact and phantom-free. It does NOT touch
        // the deploy/attest bound or the `completeInbound` principal/yield split.
        if (value6 == 0 && inFlight6 == 0 && cyclePeak6 > 0) {
            uint256 residual = outstandingFace6();
            if (residual > 0) {
                feesPaid6 += residual;
                emit FaceRetired(residual);
            }
            cyclePeak6 = 0; // the cycle is closed; a later zero sync is a no-op
        }
        ethPrincipal6 = outstandingFace6();
    }

    /// @notice Keeper: push idle USDC back to the vault (after a return lands).
    /// AUDIT F-5: the transfer is followed by the vault's return hook so the
    /// returned PRINCIPAL is booked as accounted cash — redeployable by the
    /// next `allocate()` — WITHOUT raising the vault's `_totalAssets`. The
    /// hook is best-effort (a legacy non-upgradeable vault has no such
    /// function; the money still comes home and the miss is surfaced).
    /// PRINCIPAL ONLY: `idlePrincipal6 = balance − harvestableProfit6`, so this
    /// door can never move the un-swept yield (that is `harvest()`'s door).
    function pushIdle(uint256 amount) external onlyKeeperOrOwner nonReentrant {
        uint256 bal = underlying.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) revert AAVE__NothingIdle();
        if (amount > idlePrincipal6()) revert AAVE__ExceedsPrincipalIdle();
        underlying.safeTransfer(vault, amount);
        try IVaultReturnHookAave(vault).onStrategyReturn(amount) {
            // booked as redeployable accounted cash, totalAssets unchanged
        } catch {
            emit ReturnHookUnavailable(vault, amount);
        }
        // AUDIT F-C (exact): every payment to the vault settles OUTSTANDING
        // demand only — `recallPaid6` never banks more than `recallDemand6`, so
        // a return-landed `pushIdle` with no recall in flight cannot bank a
        // credit that masks a later genuine shortfall.
        uint256 paid = recallPaid6 + amount;
        recallPaid6 = paid > recallDemand6 ? recallDemand6 : paid;
        emit IdlePushed(amount);
    }

    // ----------------------------------------------------------------- vault

    /// @notice Vault-only: pay what is idle; record the shortfall for the
    /// keeper. The venue leg is LIQUIDITY-CONDITIONAL BY VENUE DESIGN (a redeem
    /// is capped by the Hub's un-borrowed USDC and blocked by a spoke halt), so
    /// a shortfall is EXPECTED during an unwind and covered by the vault's
    /// liquid reserve — the sleeve is never the withdrawal backstop. There is
    /// deliberately NO forced unwind: the keeper retries as liquidity returns.
    /// Capped at `idlePrincipal6()`: a recall must never pay out the un-swept
    /// yield (that would land in the vault OUTSIDE `harvest()`).
    function recall(uint256 amount) external override nonReentrant {
        if (msg.sender != vault) revert AAVE__NotVault();
        if (amount == 0) return;
        uint256 idle = idlePrincipal6();
        uint256 sent = amount > idle ? idle : amount;
        if (sent > 0) underlying.safeTransfer(vault, sent);
        // AUDIT F-C (exact): the OLD code credited `sent` against the previous
        // residual AND against the current request (via `shortfall`), so it was
        // only consistent when `shortfall == 0` — an unpaid older demand could be
        // silently cleared (monitor false negative) and a partial re-request
        // double-credited (false positive). The ambiguity is now REMOVED, not
        // modelled: this call records its full `amount` as new cumulative demand
        // and its `sent` as cumulative paid. Every `recall` amount is a demand;
        // every payment (here or `pushIdle`) settles outstanding demand first.
        recallDemand6 += amount;
        uint256 paid = recallPaid6 + sent;
        recallPaid6 = paid > recallDemand6 ? recallDemand6 : paid; // settle outstanding demand only — never bank a credit
        uint256 shortfall = amount - sent;
        if (shortfall > 0) emit RecallPending(shortfall);
        emit Recalled(amount, sent);
    }

    // ----------------------------------------------------------------- views

    /// @notice Exact face still deployed out of this contract
    /// (`sentFace6 - retFace6 - feesPaid6`, floored). Exact because `feesPaid6`
    /// retires, on a CLOSED position, the face that never came home (the CCTP
    /// destination fee on the bridge legs) — so a fee never lingers as a phantom
    /// here. `retFace6` itself stays a pure received-cash counter; the monitor's
    /// face-vs-executor reconcile diffs THIS number (do not diff `retFace6`
    /// against executor receipts without subtracting `feesPaid6`).
    function outstandingFace6() public view returns (uint256) {
        uint256 gross = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        return gross > feesPaid6 ? gross - feesPaid6 : 0;
    }

    /// @notice AUDIT F-C (exact): the residual of unmet recall demand = every
    /// `recall` amount (cumulative demand) minus every payment back to the vault
    /// (`recall` `sent` + `pushIdle`), floored at 0. Derived from the two
    /// monotonic counters, so no undecidable "is this a re-request or a fresh
    /// demand?" guess is ever baked into the number. `recallPaid6` is capped at
    /// `recallDemand6`, so this is an UPPER BOUND on unmet demand once the vault
    /// re-requests a slice it never received (a `recall` carries no id) — the
    /// keeper should read that way, and `pushIdle` is the settling action.
    function pendingRecall6() public view returns (uint256) {
        return recallDemand6 > recallPaid6 ? recallDemand6 - recallPaid6 : 0;
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
    /// recall without any new vault hook.
    function idlePrincipal6() public view returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        uint256 hp = harvestableProfit6();
        return bal > hp ? bal - hp : 0;
    }

    // ---------------------------------------------------------------- harvest

    /// @dev Vault-only sweep of realized yield (mirrors DNCoreStrategy /
    /// HLEarnStrategy and the PT / sUSD3 sleeves). A keeper/owner call only
    /// settles (returns 0); the VAULT's call transfers exactly
    /// `harvestableProfit6()` so the vault's own balance-delta is the crediting
    /// measurement — no new vault code. Gating to the vault is mandatory: a
    /// keeper/owner direct sweep would land the yield at the vault OUTSIDE
    /// `harvest()` and re-create an uncredited arrival.
    function _doHarvest() internal override returns (uint256 profit) {
        if (msg.sender != owner() && msg.sender != keeper && msg.sender != vault) revert AAVE__NotKeeper();
        if (msg.sender != vault) return 0; // keeper/owner settle only; VAULT sweeps
        uint256 sweep = harvestableProfit6();
        if (sweep == 0) return 0;
        if (sweep > underlying.balanceOf(address(this))) return 0; // belt-and-braces
        profitSwept6 += sweep;
        underlying.safeTransfer(vault, sweep);
        emit ProfitSwept(sweep);
        return sweep;
    }

    // ----------------------------------------------------------------- owner

    /// @notice Owner-only bookkeeping reconciliation for `profitRealized6`
    /// (the hatch DNCoreStrategy / HLEarnStrategy / SUSD3Strategy ship). Needed
    /// because a duplicated/dropped bridge or a donation-mint can misstate the
    /// counter. Funds-safe: it only sizes future sweeps and can never be set
    /// below what has already been swept.
    ///
    /// R-3 (documented owner-trust surface, not a hard bound): there is NO UPPER
    /// BOUND. Raising `profitRealized6` above the real idle cash raises
    /// `harvestableProfit6()` too, so a subsequent vault `harvest()` could sweep
    /// PRINCIPAL as yield — reachable only by the OWNER. Mitigations are
    /// operational: treat `reconcileProfit` as a break-glass call, log the
    /// `ProfitReconciled` event, and confirm `harvestableProfit6() <=
    /// balanceOf(this)` after any reconcile.
    function reconcileProfit(uint256 newRealized) external onlyOwner {
        if (newRealized < profitSwept6) revert AAVE__BelowSwept();
        uint256 old = profitRealized6;
        profitRealized6 = newRealized;
        emit ProfitReconciled(old, newRealized);
    }

    function setParams(uint256 _headroomBps, uint256 _minBridgeUsd6) external onlyOwner nonReentrant {
        require(_headroomBps <= MAX_HEADROOM_BPS, "Aave: headroom too high");
        require(_minBridgeUsd6 >= 2e6, "Aave: min too low");
        headroomBps = _headroomBps;
        minBridgeUsd6 = _minBridgeUsd6;
        emit ParamsSet(_headroomBps, _minBridgeUsd6);
    }
}
