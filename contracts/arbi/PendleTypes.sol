// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Pendle Router v4 type declarations — EXACT field order copied from
// pendle-core-v2-public:
//   contracts/interfaces/IPAllActionTypeV3.sol
//   contracts/interfaces/IPLimitRouter.sol
//   contracts/router/swap-aggregator/IPSwapAggregator.sol
// The executor calls the live router with these types; any drift here breaks
// the call on-chain, so DO NOT reorder or rename fields.

enum SwapType {
    NONE,
    KYBERSWAP,
    ODOS,
    ETH_WETH,
    OKX,
    ONE_INCH,
    PARASWAP,
    RESERVE_2,
    RESERVE_3,
    RESERVE_4,
    RESERVE_5
}

struct SwapData {
    SwapType swapType;
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

struct TokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address pendleSwap;
    SwapData swapData;
}

struct TokenOutput {
    address tokenOut;
    uint256 minTokenOut;
    address tokenRedeemSy;
    address pendleSwap;
    SwapData swapData;
}

struct ApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

enum OrderType {
    SY_FOR_PT,
    PT_FOR_SY,
    SY_FOR_YT,
    YT_FOR_SY
}

struct Order {
    uint256 salt;
    uint256 expiry;
    uint256 nonce;
    OrderType orderType;
    address token;
    address YT;
    address maker;
    address receiver;
    uint256 makingAmount;
    uint256 lnImpliedRate;
    uint256 failSafeRate;
    bytes permit;
}

struct FillOrderParams {
    Order order;
    bytes signature;
    uint256 makingAmount;
}

struct LimitOrderData {
    address limitRouter;
    uint256 epsSkipMarket;
    FillOrderParams[] normalFills;
    FillOrderParams[] flashFills;
    bytes optData;
}

struct ExitPreExpReturnParams {
    uint256 netPtFromRemove;
    uint256 netSyFromRemove;
    uint256 netPyRedeem;
    uint256 netSyFromRedeem;
    uint256 netPtSwap;
    uint256 netYtSwap;
    uint256 netSyFromSwap;
    uint256 netSyFee;
    uint256 totalSyOut;
}

struct ExitPostExpReturnParams {
    uint256 netPtFromRemove;
    uint256 netSyFromRemove;
    uint256 netPtRedeem;
    uint256 netSyFromRedeem;
    uint256 totalSyOut;
}
