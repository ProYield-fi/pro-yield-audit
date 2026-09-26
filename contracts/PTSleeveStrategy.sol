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
///   - `sentFace6` / `retFace6` are monotonic cumulative face flows.
///   - `inFlight6`: sent but not yet acknowledged by the keeper as arrived on
///     the Arb side (counted at face — CCTP mints 1:1; outbound fee is 0 today
///     and `maxFee` is capped at deploy time anyway).
///   - `arbValue6`: keeper-attested value of the Arb position (PT + Arb idle),
///     CLAMPED to arrived-face x (1 + headroom) on every sync — the keeper can
///     never inflate the book beyond what actually left this contract.
///   - Any inbound completion subtracts the received amount from `arbValue6`
///     (never double-counts), and the keeper re-syncs the true remainder.
///
/// Trust model: the only money movements out of this contract are
/// (a) CCTP burns to the IMMUTABLE `arbExecutor`, and (b) transfers to the
/// vault. The keeper can poke and attest but cannot redirect a single cent.
contract PTSleeveStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ITokenMessengerV2Burn public immutable tokenMessenger;
    IMessageTransmitterV2Recv public immutable messageTransmitter;
    address public immutable arbExecutor; // mint target on Arbitrum (immutable)
    uint32 public immutable destDomain; // CCTP domain — Arbitrum = 3

    uint256 public constant MAX_HEADROOM_BPS = 3000; // hard cap: +30%
    uint256 public headroomBps = 2000; // default attestation headroom: +20%
    uint256 public minBridgeUsd6 = 5e6; // never bridge dust ($5)
    uint256 public constant MAX_BURN_FEE6 = 2e6; // keeper maxFee arg cap ($2)

    uint256 public sentFace6; // cumulative face sent outbound
    uint256 public retFace6; // cumulative face returned inbound
    uint256 public inFlight6; // sent, not yet acked as arrived on Arb
    uint256 public arbValue6; // keeper-attested Arb-side value
    uint256 public arbPrincipal6; // face value currently out (sent - returned)
    uint256 public syncTime; // last attestation timestamp
    uint256 public pendingRecall6; // recall asked for more than idle

    event BridgedOut(uint256 amount, uint256 maxFee);
    event InboundCompleted(uint256 received);
    event ArrivalAcked(uint256 amount);
    event ArbValueSynced(uint256 value6);
    event RecallPending(uint256 shortfall);
    event IdlePushed(uint256 amount);
    event ParamsSet(uint256 headroomBps, uint256 minBridgeUsd6);
    event Recalled(uint256 requested, uint256 returned);

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
        require(_destDomain != 0, "PT: zero domain");
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
    /// Fee-free today (verified via Circle's fee API); `maxFee` is still capped
    /// so a fee change can never silently overcharge, and the burn reverts if
    /// the live fee exceeds it (Circle enforces maxFee on-chain).
    function deployToArb(uint256 amount, uint256 maxFee) external onlyKeeperOrOwner nonReentrant {
        require(isActive, "PT: inactive");
        require(amount >= minBridgeUsd6, "PT: below min bridge");
        require(maxFee <= MAX_BURN_FEE6, "PT: maxFee too high");
        uint256 bal = underlying.balanceOf(address(this));
        require(amount <= bal, "PT: exceeds idle");
        underlying.forceApprove(address(tokenMessenger), amount);
        tokenMessenger.depositForBurn(
            amount, destDomain, bytes32(uint256(uint160(arbExecutor))), address(underlying), bytes32(0), maxFee, 1000
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
        retFace6 += received;
        arbPrincipal6 = sentFace6 > retFace6 ? sentFace6 - retFace6 : 0;
        // The returned face is now idle cash; drop it from the attested value
        // (never double-count). Keeper re-syncs the true remainder next poke.
        arbValue6 = arbValue6 > received ? arbValue6 - received : 0;
        emit InboundCompleted(received);
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
        uint256 arrivedFace = outstanding > inFlight6 ? outstanding - inFlight6 : 0;
        uint256 cap = (arrivedFace * (10000 + headroomBps)) / 10000;
        require(value6 <= cap, "PT: value above bound");
        arbValue6 = value6;
        arbPrincipal6 = outstanding;
        syncTime = block.timestamp;
        emit ArbValueSynced(value6);
    }

    /// @notice Keeper: push idle USDC back to the vault (after an unwind lands).
    function pushIdle(uint256 amount) external onlyKeeperOrOwner nonReentrant {
        uint256 bal = underlying.balanceOf(address(this));
        if (amount > bal) amount = bal;
        require(amount > 0, "PT: nothing idle");
        underlying.safeTransfer(vault, amount);
        pendingRecall6 = pendingRecall6 > amount ? pendingRecall6 - amount : 0;
        emit IdlePushed(amount);
    }

    // ----------------------------------------------------------------- vault

    /// @notice Vault-only: pay what is idle; record the shortfall for the keeper.
    /// The Arb leg is asynchronous (sell PT -> CCTP standard ~15 min -> land),
    /// so a shortfall is EXPECTED during unwinds and covered by the vault's
    /// liquid reserve (_recallShortfall measures what actually arrived).
    function recall(uint256 amount) external override nonReentrant {
        require(msg.sender == vault, "PT: not vault");
        if (amount == 0) return;
        uint256 idle = underlying.balanceOf(address(this));
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

    // ----------------------------------------------------------------- owner

    function setParams(uint256 _headroomBps, uint256 _minBridgeUsd6) external onlyOwner nonReentrant {
        require(_headroomBps <= MAX_HEADROOM_BPS, "PT: headroom too high");
        require(_minBridgeUsd6 >= 2e6, "PT: min too low");
        headroomBps = _headroomBps;
        minBridgeUsd6 = _minBridgeUsd6;
        emit ParamsSet(_headroomBps, _minBridgeUsd6);
    }
}
