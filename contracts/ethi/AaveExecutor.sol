// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal ERC-4626 surface (the Aave Tokenization Spoke is a plain
/// ERC-4626 wrapper: asset() = USDC, 6 decimals).
interface IERC4626MinAave {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function maxDeposit(address owner) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice The Aave v4 Hub surface used for exit-depth reads (`assetId()` on
/// the spoke + `getAssetLiquidity()` on the Hub — the un-borrowed USDC a redeem
/// can actually pull at that block).
interface IAaveSpokeMin {
    function assetId() external view returns (uint256);
    function hub() external view returns (address);
}

interface IAaveHubMin {
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);
}

interface ITokenMessengerV2BurnAaveEth {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /// @dev AUDIT F-A (deploy leg): derived transmitter — no new constructor arg.
    function localMessageTransmitter() external view returns (address);
}

interface IMessageTransmitterV2RecvAave {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/// @title AaveExecutor — Ethereum-side executor for the Frontier Aave v4 sleeve.
///
/// Sibling of `SUSD3Executor` / `PTSleeveEthExecutor`: same trust model, same
/// ops surface. The venue difference is the LIFECYCLE: Aave v4's USDC
/// Tokenization Spoke is a **synchronous ERC-4626** wrapper — `deposit` in,
/// `redeem` out, no cooldown — so the whole exit door is ONE capped call
/// instead of sUSD3's start/wait/complete state machine.
///
/// Capital path in :  HyperEVM vault -> AaveStrategy -> CCTP burn (domain 0)
///   -> THIS -> ops `enter`: USDC --ERC-4626 deposit--> waPrimeUSDC shares
/// Position      :  waPrimeUSDC shares held HERE
/// Capital path out: ops `exit`: shares --redeem--> USDC, CAPPED by the
///   venue's own `maxRedeem` (the Hub's available USDC at that block) ->
///   ops `bridgeBack`: CCTP standard transfer -> the HyperEVM strategy
///   (immutable recipient)
///
/// LIQUIDITY-CONDITIONAL EXIT — NO FORCED UNWIND (AAVE_DD §5): a redeem is
/// capped by the Hub's un-borrowed USDC and is blocked outright by a spoke
/// halt / reserve pause. `exit` therefore:
///   - caps the request at `min(shares, maxRedeem(this))` and redeems exactly
///     that (a partially-utilized position unwinds in slices), and
///   - reverts `AAVE_E__NoLiquidity` when NOTHING is redeemable, so ops sees an
///     explicit, retryable signal instead of a silent no-op.
/// There is deliberately no path that forces the venue to sell anything.
///
/// Trust model (identical to the PT / sUSD3 executors):
///  - `ops` (keeper key) can ONLY: deposit USDC into the configured ERC-4626
///    spoke, redeem shares back to USDC, and burn USDC to the IMMUTABLE
///    `strategyReturn` address on HyperEVM. It can never move funds anywhere
///    else and can never change configuration.
///  - `owner` (the 2/3 treasury Safe) holds the one-time return-destination
///    correction (bootstrap) and the rescue hatch.
///  - Every leg takes min-out bounds from the caller, re-asserted here against
///    the ACTUAL received amount (balance delta, never the venue's claim).
///  - Aave USDC supply is senior/simple lending, but it is NOT risk-free: a
///    liquidation shortfall can impair the Hub asset. This contract never hides
///    that — balances are what they are; the strategy's attestation records the
///    mark and a downward sync fires `LossObserved`.
contract AaveExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC4626MinAave public immutable spoke; // the USDC Tokenization Spoke (waPrimeUSDC)
    ITokenMessengerV2BurnAaveEth public immutable tokenMessenger;
    /// @dev AUDIT F-A (deploy leg): the transmitter PAIRED with `tokenMessenger`,
    /// derived on-chain at construction (never a constructor argument).
    IMessageTransmitterV2RecvAave public immutable messageTransmitter;
    uint32 public constant HYPEREVM_DOMAIN = 19;

    /// @dev The HyperEVM strategy address (bytes32) that bridgeBack mints to.
    /// Set at construction from the deploy script's plan; `confirmStrategyReturn`
    /// lets the owner correct it ONCE before any activity (deploy-order
    /// bootstrap safety net), then it is locked forever.
    bytes32 public strategyReturn;
    bool public returnConfirmed;

    address public ops;

    uint256 public enterCount;
    uint256 public exitCount;
    uint256 public bridgeBackCount;

    event OpsSet(address indexed ops);
    event Entered(uint256 usdcIn, uint256 sharesOut);
    event Exited(uint256 sharesIn, uint256 usdcOut, uint256 sharesRemaining);
    event BridgedBack(uint256 amount, uint256 maxFee);
    event ArrivalRelayed(uint256 received);
    event StrategyReturnConfirmed(address indexed strategy);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error AAVE_E__NotOps();
    error AAVE_E__NotOpsOrOwner();
    error AAVE_E__ReceiveFailed();
    error AAVE_E__NothingMinted();
    error AAVE_E__ZeroAddr();
    error AAVE_E__BadAmount();
    error AAVE_E__Slippage();
    error AAVE_E__AlreadyConfirmed();
    error AAVE_E__TooLate();
    error AAVE_E__NotConfirmed();
    error AAVE_E__NoLiquidity();
    error AAVE_E__AddCap();
    error AAVE_E__Shape();

    modifier onlyOps() {
        if (msg.sender != ops) revert AAVE_E__NotOps();
        _;
    }

    /// @dev AUDIT F-A (deploy leg): `ops` = keeper key; `owner` = the 2/3 Safe —
    /// the permanent recovery path if that key rotates.
    modifier onlyOpsOrOwner() {
        if (msg.sender != ops && msg.sender != owner()) revert AAVE_E__NotOpsOrOwner();
        _;
    }

    constructor(
        address _usdc,
        address _spoke,
        address _tokenMessenger,
        address _strategyReturn,
        address _ops,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            _usdc == address(0) || _spoke == address(0) || _tokenMessenger == address(0)
                || _strategyReturn == address(0) || _ops == address(0)
        ) revert AAVE_E__ZeroAddr();
        // the spoke's underlying MUST be USDC (venue shape guard — a wrong
        // wrapper would silently strand funds in a different asset)
        if (IERC4626MinAave(_spoke).asset() != _usdc) revert AAVE_E__Shape();
        usdc = IERC20(_usdc);
        spoke = IERC4626MinAave(_spoke);
        tokenMessenger = ITokenMessengerV2BurnAaveEth(_tokenMessenger);
        // AUDIT F-A (deploy leg): derived, never passed in.
        address _mt = ITokenMessengerV2BurnAaveEth(_tokenMessenger).localMessageTransmitter();
        if (_mt == address(0)) revert AAVE_E__ZeroAddr();
        messageTransmitter = IMessageTransmitterV2RecvAave(_mt);
        strategyReturn = bytes32(uint256(uint160(_strategyReturn)));
        ops = _ops;
    }

    function setOps(address _ops) external onlyOwner {
        if (_ops == address(0)) revert AAVE_E__ZeroAddr();
        ops = _ops;
        emit OpsSet(_ops);
    }

    /// @notice One-time correction of the return destination (bootstrap safety
    /// net for deploy-order address prediction). Locks forever after — and is
    /// refused as soon as ANY activity has happened.
    function confirmStrategyReturn(address _strategy) external onlyOwner {
        if (returnConfirmed) revert AAVE_E__AlreadyConfirmed();
        if (enterCount != 0 || exitCount != 0 || bridgeBackCount != 0) revert AAVE_E__TooLate();
        if (_strategy == address(0)) revert AAVE_E__ZeroAddr();
        strategyReturn = bytes32(uint256(uint160(_strategy)));
        returnConfirmed = true;
        emit StrategyReturnConfirmed(_strategy);
    }

    /// @notice Ops: wrap idle USDC into the position (one ERC-4626 deposit).
    /// The min-out bound is re-asserted against the ACTUAL shares received.
    function enter(uint256 usdcAmount, uint256 minShares) external onlyOps nonReentrant returns (uint256 sharesOut) {
        if (usdcAmount == 0 || usdcAmount > usdc.balanceOf(address(this))) revert AAVE_E__BadAmount();
        // HALT / ADD-CAP EDGE: a halted spoke (or one whose add cap is
        // exhausted) reports maxDeposit 0 — fail with an explicit, retryable
        // error instead of a venue-level revert string.
        if (usdcAmount > spoke.maxDeposit(address(this))) revert AAVE_E__AddCap();
        usdc.forceApprove(address(spoke), usdcAmount);
        uint256 before = spoke.balanceOf(address(this));
        spoke.deposit(usdcAmount, address(this));
        sharesOut = spoke.balanceOf(address(this)) - before;
        if (sharesOut < minShares) revert AAVE_E__Slippage();
        enterCount += 1;
        emit Entered(usdcAmount, sharesOut);
    }

    /// @notice Ops: redeem shares back to USDC — CAPPED by the venue's own
    /// `maxRedeem` (Hub available USDC at this block; 0 when halted). A partial
    /// unwind is normal and expected; the caller re-calls as liquidity returns.
    /// Reverts `NoLiquidity` when nothing is redeemable (explicit, retryable —
    /// never a silent no-op and never a forced unwind).
    /// @return sharesRedeemed the shares actually burned (<= requested)
    /// @return usdcOut the USDC actually received
    function exit(uint256 shares, uint256 minUsdcOut)
        external
        onlyOps
        nonReentrant
        returns (uint256 sharesRedeemed, uint256 usdcOut)
    {
        if (shares == 0) revert AAVE_E__BadAmount();
        uint256 redeemable = spoke.maxRedeem(address(this));
        sharesRedeemed = shares > redeemable ? redeemable : shares;
        if (sharesRedeemed == 0) revert AAVE_E__NoLiquidity();
        uint256 before = usdc.balanceOf(address(this));
        spoke.redeem(sharesRedeemed, address(this), address(this));
        usdcOut = usdc.balanceOf(address(this)) - before;
        if (usdcOut < minUsdcOut) revert AAVE_E__Slippage();
        exitCount += 1;
        emit Exited(sharesRedeemed, usdcOut, spoke.balanceOf(address(this)));
    }

    /// @notice Ops: burn USDC back to the HyperEVM strategy via CCTP
    /// (standard transfer, minFinalityThreshold 2000; fee-free today,
    /// destination IMMUTABLE — ops cannot redirect it).
    ///
    /// AUDIT F-B (HIGH): refuses until the owner has blessed the destination
    /// (`returnConfirmed`). Before this gate, the FIRST normal unwind burned
    /// real USDC to whatever address the deploy script predicted, and
    /// `confirmStrategyReturn` refuses to run once `bridgeBackCount != 0` — so
    /// a wrong prediction was permanently unrecoverable. Now the return leg is
    /// unusable until the two-sided binding is explicitly confirmed.
    ///
    /// AUDIT F-A (HIGH): the burn pins `destinationCaller = strategyReturn`
    /// (was `bytes32(0)` = "any address may complete"). Circle CCTP messages are
    /// single-use, so an unpinned return let an unprivileged front-runner
    /// complete the inbound mint directly and consume the nonce, after which
    /// the strategy's `completeInbound` (the ONLY writer of `retFace6`) could
    /// never book the return. With the caller pinned, only the strategy address
    /// can complete, and only through `completeInbound`.
    function bridgeBack(uint256 amount, uint256 maxFee) external onlyOps nonReentrant {
        if (!returnConfirmed) revert AAVE_E__NotConfirmed();
        if (amount == 0 || amount > usdc.balanceOf(address(this))) revert AAVE_E__BadAmount();
        usdc.forceApprove(address(tokenMessenger), amount);
        tokenMessenger.depositForBurn(
            amount, HYPEREVM_DOMAIN, strategyReturn, address(usdc), strategyReturn, maxFee, 2000
        );
        bridgeBackCount += 1;
        emit BridgedBack(amount, maxFee);
    }

    /// @notice Ops/Safe: relay a COMPLETED deploy-leg CCTP message into this
    /// executor. AUDIT F-A (deploy leg) — the strategy's outbound burn pins
    /// `destinationCaller = THIS executor`, so the relay must live here.
    /// `MessageTransmitterV2` validates the attestation/domain/nonce and the mint
    /// recipient is fixed in the message body; a zero delta refuses any message
    /// that does not pay this contract (not a free relay service).
    /// ops = keeper EOA; owner = the 2/3 Safe (survives a key rotation).
    function relayArrival(bytes calldata message, bytes calldata attestation)
        external
        onlyOpsOrOwner
        nonReentrant
        returns (uint256 received)
    {
        uint256 before = usdc.balanceOf(address(this));
        if (!messageTransmitter.receiveMessage(message, attestation)) revert AAVE_E__ReceiveFailed();
        received = usdc.balanceOf(address(this)) - before;
        if (received == 0) revert AAVE_E__NothingMinted();
        emit ArrivalRelayed(received);
    }

    /// @notice Owner (2/3 Safe) rescue hatch — e.g. a venue migration or a
    /// stranded token. Ops can NOT call this.
    function ownerRescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert AAVE_E__ZeroAddr();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ----------------------------------------------------------------- views

    function usdcBalance() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function sharesBalance() public view returns (uint256) {
        return spoke.balanceOf(address(this));
    }

    /// @notice Shares redeemable RIGHT NOW (Hub liquidity + halt aware) — the
    /// exact cap `exit` applies. 0 = temporarily illiquid, retry later.
    function redeemableShares() public view returns (uint256) {
        return spoke.maxRedeem(address(this));
    }

    /// @notice USDC the venue would release right now (0 while fully utilized
    /// or halted). This is the exit-depth number the keeper watches.
    function redeemableUsd6() public view returns (uint256) {
        return spoke.convertToAssets(redeemableShares());
    }

    /// @notice Add-cap headroom left on the spoke at this block ($0 when the
    /// per-spoke add cap is exhausted or the spoke is halted).
    function depositHeadroomUsd6() public view returns (uint256) {
        return spoke.maxDeposit(address(this));
    }

    /// @notice USDC value of the whole position (idle USDC + the ERC-4626
    /// mark). Read-only; never trust it as a guarantee — a Hub deficit marks it
    /// down and the strategy records that honestly.
    function positionValueUsd6() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + spoke.convertToAssets(spoke.balanceOf(address(this)));
    }

    /// @notice Venue context for the keeper/runbook: the spoke, its Hub, the
    /// Hub assetId, the Hub's available USDC and the current PPS.
    /// `hub_ == address(0)` (or `assetId_ == 0`) means the venue mapping is
    /// WRONG — treat it as a config error, never as "zero liquidity".
    function venueReadout()
        external
        view
        returns (address spoke_, address hub_, uint256 assetId_, uint256 hubLiquidity6_, uint256 pps1e6_)
    {
        spoke_ = address(spoke);
        assetId_ = IAaveSpokeMin(address(spoke)).assetId();
        hub_ = IAaveSpokeMin(address(spoke)).hub();
        if (hub_ != address(0)) hubLiquidity6_ = IAaveHubMin(hub_).getAssetLiquidity(assetId_);
        pps1e6_ = spoke.convertToAssets(1e6);
    }
}
