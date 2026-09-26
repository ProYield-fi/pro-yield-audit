// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockUSDC} from "./MockUSDC.sol";

/// @notice Minimal mock of the Curve USDC/USDai stable pool the executor hops
/// through (mirrors the live pool's index layout: 0 = USDai, 1 = USDC).
/// 1:1 rate minus `feeBps`; 6dp/18dp conversion follows the repo's test
/// convention (MockUSDC carries the "6dp" quantities, USDai the scaled 18dp).
contract MockCurve {
    MockUSDC public usdc;
    MockUSDC public usdai;
    uint256 public feeBps = 4; // 0.04% stable fee, close to the live pool

    constructor(address _usdc, address _usdai) {
        usdc = MockUSDC(_usdc);
        usdai = MockUSDC(_usdai);
    }

    function setFee(uint256 f) external {
        feeBps = f;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external {
        if (i == 1 && j == 0) {
            // USDC (idx 1) → USDai (idx 0)
            usdc.transferFrom(msg.sender, address(this), dx);
            uint256 dy = dx * 1e12;
            dy -= (dy * feeBps) / 10000;
            require(dy >= minDy, "curve: slippage");
            usdai.mint(msg.sender, dy);
        } else if (i == 0 && j == 1) {
            // USDai (idx 0) → USDC (idx 1)
            usdai.transferFrom(msg.sender, address(this), dx);
            uint256 dy = dx / 1e12;
            dy -= (dy * feeBps) / 10000;
            require(dy >= minDy, "curve: slippage");
            usdc.mint(msg.sender, dy);
        } else {
            revert("curve: bad indices");
        }
    }
}
