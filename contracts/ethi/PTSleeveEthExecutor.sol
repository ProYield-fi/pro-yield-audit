// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    TokenInput,
    TokenOutput,
    ApproxParams,
    LimitOrderData,
    FillOrderParams,
    SwapData,
    SwapType
} from "../arbi/PendleTypes.sol";

interface IPendleRouterMin {
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
}

interface ITokenMessengerV2BurnEth {
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

interface ICurvePoolEth {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external;
}

/// @notice Ethereum-side executor for the Pendle PT fixed-rate sleeve (ETH lane).
///
/// Sibling of the live Arbitrum executor (contracts/arbi/PTSleeveExecutor.sol):
/// same trust model, same ops surface — only the deployment differs (Ethereum
/// mainnet, CCTP domain 0, USDC -> apxUSD Curve hop -> Pendle router).
///
/// Holds USDC that arrives via CCTP from the HyperEVM strategy, buys/sells PT
/// through the Pendle router (v4, immutable), and burns USDC back through
/// CCTP to the HyperEVM strategy.
///
/// Trust model (identical to the Arb executor):
///  - `ops` (keeper key) can ONLY: buy PT on the configured market, sell PT on
///    the configured market, and burn USDC back to the `strategyReturn` address
///    on HyperEVM (fixed at deploy, correctable ONCE by the owner before any
///    activity, then locked). It can never move funds anywhere else and can
///    never change configuration.
///  - `owner` (the 2/3 treasury Safe) sets the market/PT pair (for rolls), the
///    ops key, and holds the rescue hatch (owner-only token transfer — e.g.
///    to redeem PT after expiry via the Safe).
///  - Every buy/sell takes min-out parameters from the caller, enforced by the
///    router AND re-asserted here.
///
/// Hop leg note: the Pendle SY for the apxUSD market accepts apxUSD as the
/// input token [verified live 2026-09-30: market inputTokens = apxUSD] and
/// returns it on exit, so the Curve hop (USDC <-> apxUSD) is the only venue
/// besides the Pendle router this contract may touch.
/// Exit routing: some markets' SY accepts `asset` on entry but returns a
/// DIFFERENT token on exit (apyUSD-5NOV: in = apxUSD, out = apyUSD). The
/// owner sets the exit route (`setExitPath`): symmetric (default) or an
/// extra hop through `exitPool` back into `asset` — see sellPT. Same source
/// ships to both flavors; a new asset family = a new instance.
/// A new asset family = a new executor instance (immutables), same as the
/// Arb side.
contract PTSleeveEthExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IPendleRouterMin public immutable router;
    ITokenMessengerV2BurnEth public immutable tokenMessenger;
    address public immutable asset; // stable the Pendle SY accepts (apxUSD)
    ICurvePoolEth public immutable curve; // USDC <-> asset hop (Curve stableswap-ng)
    int128 public immutable curveIdxUsdc;
    int128 public immutable curveIdxAsset;
    uint32 public constant HYPEREVM_DOMAIN = 19;

    /// @dev The HyperEVM strategy address (bytes32) that bridgeBack mints to.
    /// Set at construction from the deploy script's address prediction/plan;
    /// `confirmStrategyReturn` lets the owner correct it ONCE before any
    /// activity (deploy-order bootstrap safety net), then it is locked forever.
    bytes32 public strategyReturn;
    bool public returnConfirmed;

    address public ops;
    address public market; // Pendle market — owner-set (rolls)
    address public pt; // PT token of that market — owner-set

    /// Exit route (owner-configurable per current market).
    ///  - symmetric mode: `exitAsset == asset && exitPool == 0`
    ///    → exit is PT -> asset (Pendle) -> USDC (one Curve hop).
    ///  - two-hop mode: `exitAsset != asset && exitPool != 0`
    ///    → exit is PT -> exitAsset (Pendle) -> asset (exitPool hop)
    ///      -> USDC (main Curve hop). Needed when the market's SY accepts
    ///    `asset` on entry but returns a different token on exit (e.g. the
    ///    apyUSD-5NOV market: in = apxUSD, out = apyUSD).
    address public exitAsset;
    address public exitPool;
    int128 public exitIdxFrom;
    int128 public exitIdxTo;

    uint256 public buyCount;
    uint256 public sellCount;
    uint256 public bridgeBackCount;

    event OpsSet(address indexed ops);
    event MarketSet(address indexed market, address indexed pt);
    event ExitPathSet(address exitAsset, address exitPool, int128 idxFrom, int128 idxTo);
    event BoughtPt(uint256 usdcIn, uint256 ptOut);
    event SoldPt(uint256 ptIn, uint256 usdcOut);
    event BridgedBack(uint256 amount, uint256 maxFee);
    event StrategyReturnConfirmed(address indexed strategy);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOps() {
        require(msg.sender == ops, "PTE: not ops");
        _;
    }

    constructor(
        address _usdc,
        address _router,
        address _tokenMessenger,
        address _strategyReturn,
        address _ops,
        address initialOwner,
        address _asset,
        address _curve,
        int128 _idxUsdc,
        int128 _idxAsset
    ) Ownable(initialOwner) {
        require(
            _usdc != address(0) && _router != address(0) && _tokenMessenger != address(0)
                && _strategyReturn != address(0) && _ops != address(0)
                && _asset != address(0) && _curve != address(0),
            "PTE: zero addr"
        );
        require(_idxUsdc != _idxAsset, "PTE: same indices");
        usdc = IERC20(_usdc);
        router = IPendleRouterMin(_router);
        tokenMessenger = ITokenMessengerV2BurnEth(_tokenMessenger);
        strategyReturn = bytes32(uint256(uint160(_strategyReturn)));
        ops = _ops;
        asset = _asset;
        curve = ICurvePoolEth(_curve);
        curveIdxUsdc = _idxUsdc;
        curveIdxAsset = _idxAsset;
        exitAsset = _asset; // default: symmetric (no extra hop)
    }

    function setOps(address _ops) external onlyOwner {
        require(_ops != address(0), "PTE: zero ops");
        ops = _ops;
        emit OpsSet(_ops);
    }

    /// @notice Point at the market/PT pair for the current maturity.
    function setMarket(address _market, address _pt) external onlyOwner {
        require(_market != address(0) && _pt != address(0), "PTE: zero market");
        market = _market;
        pt = _pt;
        emit MarketSet(_market, _pt);
    }

    /// @notice Owner-set exit route for the CURRENT/next market (roll-time
    /// config). Symmetric mode = `_exitPool == 0` (requires `_exitAsset ==
    /// asset`). Two-hop mode = `_exitPool != 0` (requires `_exitAsset !=
    /// asset`). Ops can NOT call this; the worst a compromised owner can do
    /// here is point the hop at a pool that reverts (funds always end as
    /// USDC in THIS contract — min-out bounds are enforced per leg).
    function setExitPath(address _exitAsset, address _exitPool, int128 _idxFrom, int128 _idxTo) external onlyOwner {
        require(_exitAsset != address(0), "PTE: zero exit asset");
        if (_exitPool == address(0)) {
            require(_exitAsset == asset, "PTE: symmetric needs asset");
            require(_idxFrom == 0 && _idxTo == 0, "PTE: idx must be zero");
        } else {
            require(_exitAsset != asset, "PTE: redundant hop");
            require(_idxFrom != _idxTo, "PTE: same idx");
        }
        exitAsset = _exitAsset;
        exitPool = _exitPool;
        exitIdxFrom = _idxFrom;
        exitIdxTo = _idxTo;
        emit ExitPathSet(_exitAsset, _exitPool, _idxFrom, _idxTo);
    }

    /// @notice One-time correction of the return destination (bootstrap safety
    /// net for deploy-order address prediction). Locks forever after — and is
    /// refused as soon as ANY buy/sell/return has happened.
    function confirmStrategyReturn(address _strategy) external onlyOwner {
        require(!returnConfirmed, "PTE: already confirmed");
        require(buyCount == 0 && sellCount == 0 && bridgeBackCount == 0, "PTE: too late");
        require(_strategy != address(0), "PTE: zero strategy");
        strategyReturn = bytes32(uint256(uint160(_strategy)));
        returnConfirmed = true;
        emit StrategyReturnConfirmed(_strategy);
    }

    /// @notice Buy PT: USDC -> Curve hop -> asset (apxUSD) -> Pendle market -> PT.
    function buyPT(uint256 usdcAmount, uint256 minAssetOut, uint256 minPtOut) external onlyOps nonReentrant returns (uint256 ptOut) {
        require(market != address(0), "PTE: no market");
        require(usdcAmount > 0 && usdcAmount <= usdc.balanceOf(address(this)), "PTE: bad amount");
        // Hop 1: USDC -> asset on Curve.
        usdc.forceApprove(address(curve), usdcAmount);
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        curve.exchange(curveIdxUsdc, curveIdxAsset, usdcAmount, minAssetOut);
        uint256 got = IERC20(asset).balanceOf(address(this)) - assetBefore;
        require(got >= minAssetOut, "PTE: curve slippage");
        // Hop 2: asset -> PT on Pendle.
        IERC20(asset).forceApprove(address(router), got);
        TokenInput memory input = TokenInput({
            tokenIn: asset,
            netTokenIn: got,
            tokenMintSy: asset,
            pendleSwap: address(0),
            swapData: _noSwap()
        });
        (ptOut,,) = router.swapExactTokenForPt(
            address(this),
            market,
            minPtOut,
            ApproxParams({guessMin: 0, guessMax: type(uint256).max, guessOffchain: 0, maxIteration: 256, eps: 1e14}),
            input,
            _emptyLimit()
        );
        require(ptOut >= minPtOut, "PTE: slippage");
        buyCount += 1;
        emit BoughtPt(usdcAmount, ptOut);
    }

    /// @notice Sell PT: PT -> Pendle -> exitAsset [-> asset via exitPool]
    /// -> Curve hop -> USDC. Min-out bounds are enforced per leg:
    ///   - minExitOut: bound on the Pendle leg output (exitAsset units);
    ///   - minMidOut:  bound on the exitPool hop output (asset units; in
    ///     symmetric mode the same value also bounds the Pendle output —
    ///     pass 0 if unused);
    ///   - minUsdcOut: bound on the final USDC out.
    /// Ops must roll PRE-EXPIRY (design: >= 3 days before maturity); after
    /// expiry the owner Safe uses the rescue hatch for manual redemption.
    function sellPT(uint256 ptAmount, uint256 minExitOut, uint256 minMidOut, uint256 minUsdcOut)
        external
        onlyOps
        nonReentrant
        returns (uint256 usdcOut)
    {
        require(market != address(0) && pt != address(0), "PTE: no market");
        require(ptAmount > 0 && ptAmount <= IERC20(pt).balanceOf(address(this)), "PTE: bad amount");
        // Leg 1: PT -> exitAsset on Pendle.
        IERC20(pt).forceApprove(address(router), ptAmount);
        TokenOutput memory output = TokenOutput({
            tokenOut: exitAsset,
            minTokenOut: minExitOut,
            tokenRedeemSy: exitAsset,
            pendleSwap: address(0),
            swapData: _noSwap()
        });
        uint256 exitOut;
        (exitOut,,) = router.swapExactPtForToken(address(this), market, ptAmount, output, _emptyLimit());
        require(exitOut >= minExitOut, "PTE: slippage");
        // Leg 2 (optional): exitAsset -> asset via exitPool.
        uint256 midAsset;
        if (exitPool != address(0)) {
            IERC20(exitAsset).forceApprove(exitPool, exitOut);
            uint256 assetBefore = IERC20(asset).balanceOf(address(this));
            ICurvePoolEth(exitPool).exchange(exitIdxFrom, exitIdxTo, exitOut, minMidOut);
            midAsset = IERC20(asset).balanceOf(address(this)) - assetBefore;
        } else {
            midAsset = exitOut; // symmetric mode
        }
        require(midAsset >= minMidOut, "PTE: slippage");
        // Leg 3: asset -> USDC on Curve.
        IERC20(asset).forceApprove(address(curve), midAsset);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        curve.exchange(curveIdxAsset, curveIdxUsdc, midAsset, minUsdcOut);
        usdcOut = usdc.balanceOf(address(this)) - usdcBefore;
        require(usdcOut >= minUsdcOut, "PTE: slippage");
        sellCount += 1;
        emit SoldPt(ptAmount, usdcOut);
    }

    /// @notice Burn USDC back to the HyperEVM strategy via CCTP.
    /// STANDARD transfer (minFinalityThreshold = 2000): fee-free today (verified
    /// via Circle's fee API for Ethereum -> HyperEVM), ~15+ min.
    /// Destination is the IMMUTABLE strategyReturn — ops cannot redirect it.
    function bridgeBack(uint256 amount, uint256 maxFee) external onlyOps nonReentrant {
        require(amount > 0 && amount <= usdc.balanceOf(address(this)), "PTE: bad amount");
        usdc.forceApprove(address(tokenMessenger), amount);
        tokenMessenger.depositForBurn(
            amount, HYPEREVM_DOMAIN, strategyReturn, address(usdc), bytes32(0), maxFee, 2000
        );
        bridgeBackCount += 1;
        emit BridgedBack(amount, maxFee);
    }

    /// @notice Owner (2/3 Safe) rescue hatch — e.g. post-expiry PT handling or
    /// a market migration. Ops can NOT call this.
    function ownerRescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "PTE: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ----------------------------------------------------------------- views

    function ptBalance() external view returns (uint256) {
        return pt == address(0) ? 0 : IERC20(pt).balanceOf(address(this));
    }

    function usdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ------------------------------------------------------------- internal

    function _noSwap() internal pure returns (SwapData memory) {
        return SwapData({swapType: SwapType.NONE, extRouter: address(0), extCalldata: "", needScale: false});
    }

    function _emptyLimit() internal pure returns (LimitOrderData memory) {
        return LimitOrderData({
            limitRouter: address(0),
            epsSkipMarket: 0,
            normalFills: new FillOrderParams[](0),
            flashFills: new FillOrderParams[](0),
            optData: ""
        });
    }
}
