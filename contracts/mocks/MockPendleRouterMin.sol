// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockUSDC} from "./MockUSDC.sol";
import {MockPT} from "./MockCctp.sol";
import {TokenInput, TokenOutput, ApproxParams, LimitOrderData} from "../arbi/PendleTypes.sol";

/// @notice Minimal mock of the Pendle Router v4 PT swap surface.
/// The SY leg token is `usdai` (the executor does the USDC hop on Curve
/// before/after). Buying mints PT at `ptPrice18` USDai/PT; selling pays
/// USDai at the same price. Enforces the router's min-out semantics.
contract MockPendleRouterMin {
    MockUSDC public usdai;
    MockPT public pt;

    uint256 public ptPrice18 = 0.995e18; // USDai per PT (18dp)
    uint256 public buyCount;
    uint256 public sellCount;

    constructor(address _usdai, address _pt) {
        usdai = MockUSDC(_usdai);
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
        require(input.tokenIn == address(usdai), "mockrouter: tokenIn");
        usdai.transferFrom(msg.sender, address(this), input.netTokenIn);
        netPtOut = (input.netTokenIn * 1e18) / ptPrice18; // 18dp USDai at price -> PT
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
        require(output.tokenOut == address(usdai), "mockrouter: tokenOut");
        pt.transferFrom(msg.sender, address(this), exactPtIn);
        netTokenOut = (exactPtIn * ptPrice18) / 1e18; // PT -> 18dp USDai at price
        require(netTokenOut >= output.minTokenOut, "router: minTokenOut");
        usdai.mint(receiver, netTokenOut);
        sellCount += 1;
        return (netTokenOut, 0, 0);
    }
}
