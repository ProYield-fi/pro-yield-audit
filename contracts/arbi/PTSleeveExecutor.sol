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
} from "./PendleTypes.sol";

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

interface ITokenMessengerV2BurnArb {
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

/// @notice Arbitrum-side executor for the Pendle PT fixed-rate sleeve.
///
/// Holds USDC that arrives via CCTP from the HyperEVM strategy, buys/sells PT
/// through the Pendle router (v4, immutable), and burns USDC back through
/// CCTP to the HyperEVM strategy.
///
/// Trust model:
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
contract PTSleeveExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IPendleRouterMin public immutable router;
    ITokenMessengerV2BurnArb public immutable tokenMessenger;
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

    uint256 public buyCount;
    uint256 public sellCount;
    uint256 public bridgeBackCount;

    event OpsSet(address indexed ops);
    event MarketSet(address indexed market, address indexed pt);
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
        address initialOwner
    ) Ownable(initialOwner) {
        require(
            _usdc != address(0) && _router != address(0) && _tokenMessenger != address(0)
                && _strategyReturn != address(0) && _ops != address(0),
            "PTE: zero addr"
        );
        usdc = IERC20(_usdc);
        router = IPendleRouterMin(_router);
        tokenMessenger = ITokenMessengerV2BurnArb(_tokenMessenger);
        strategyReturn = bytes32(uint256(uint160(_strategyReturn)));
        ops = _ops;
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

    /// @notice Buy PT with USDC on the configured market. minPtOut bounds slippage.
    function buyPT(uint256 usdcAmount, uint256 minPtOut) external onlyOps nonReentrant returns (uint256 ptOut) {
        require(market != address(0), "PTE: no market");
        require(usdcAmount > 0 && usdcAmount <= usdc.balanceOf(address(this)), "PTE: bad amount");
        usdc.forceApprove(address(router), usdcAmount);
        TokenInput memory input = TokenInput({
            tokenIn: address(usdc),
            netTokenIn: usdcAmount,
            tokenMintSy: address(usdc),
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

    /// @notice Sell PT for USDC on the configured market. minUsdcOut bounds slippage.
    /// Ops must roll PRE-EXPIRY (design: >= 3 days before maturity); after
    /// expiry the owner Safe uses the rescue hatch for manual redemption.
    function sellPT(uint256 ptAmount, uint256 minUsdcOut) external onlyOps nonReentrant returns (uint256 usdcOut) {
        require(market != address(0) && pt != address(0), "PTE: no market");
        require(ptAmount > 0 && ptAmount <= IERC20(pt).balanceOf(address(this)), "PTE: bad amount");
        IERC20(pt).forceApprove(address(router), ptAmount);
        TokenOutput memory output = TokenOutput({
            tokenOut: address(usdc),
            minTokenOut: minUsdcOut,
            tokenRedeemSy: address(usdc),
            pendleSwap: address(0),
            swapData: _noSwap()
        });
        (usdcOut,,) = router.swapExactPtForToken(address(this), market, ptAmount, output, _emptyLimit());
        require(usdcOut >= minUsdcOut, "PTE: slippage");
        sellCount += 1;
        emit SoldPt(ptAmount, usdcOut);
    }

    /// @notice Burn USDC back to the HyperEVM strategy via CCTP.
    /// STANDARD transfer (minFinalityThreshold = 2000): fee-free today, ~15 min.
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
