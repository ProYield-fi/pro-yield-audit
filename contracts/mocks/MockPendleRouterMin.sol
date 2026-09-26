// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockUSDC} from "./MockUSDC.sol";
import {MockPT} from "./MockCctp.sol";
import {TokenInput, TokenOutput, ApproxParams, LimitOrderData} from "../arbi/PendleTypes.sol";

/// @notice Minimal mock of the Pendle Router v4 PT swap surface.
/// Buying mints PT at `ptPrice18` USD/PT; selling pays USDC at the same price.
/// Enforces the router's min-out semantics (revert messages mirror the real ones
/// closely enough for the guards under test).
contract MockPendleRouterMin {
    MockUSDC public usdc;
    MockPT public pt;

    uint256 public ptPrice18 = 0.995e18; // USD per PT (18dp)
    uint256 public buyCount;
    uint256 public sellCount;

    constructor(address _usdc, address _pt) {
        usdc = MockUSDC(_usdc);
        pt = MockPT(_pt);
    }

    function setPrice(uint256 p) external {
        require(p > 0, "mockrouter: zero price");
        ptPrice18 = p;
    }

    function swapExactTokenForPt(
        address receiver,
        address,
        uint256 minPtOut,
        ApproxParams calldata,
        TokenInput calldata input,
        LimitOrderData calldata
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm) {
        require(input.tokenIn == address(usdc), "mockrouter: tokenIn");
        usdc.transferFrom(msg.sender, address(this), input.netTokenIn);
        netPtOut = (input.netTokenIn * 1e12 * 1e18) / ptPrice18; // 6dp -> 18dp / price
        require(netPtOut >= minPtOut, "router: minPtOut");
        pt.mint(receiver, netPtOut);
        buyCount += 1;
        return (netPtOut, 0, 0);
    }

    function swapExactPtForToken(
        address receiver,
        address,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) {
        require(output.tokenOut == address(usdc), "mockrouter: tokenOut");
        pt.transferFrom(msg.sender, address(this), exactPtIn);
        netTokenOut = (exactPtIn * ptPrice18) / 1e18 / 1e12; // 18dp -> 6dp * price
        require(netTokenOut >= output.minTokenOut, "router: minTokenOut");
        usdc.mint(receiver, netTokenOut);
        sellCount += 1;
        return (netTokenOut, 0, 0);
    }
}
