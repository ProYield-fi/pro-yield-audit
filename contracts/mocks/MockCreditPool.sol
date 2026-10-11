// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test credit pool (junior-tranche stand-in): 1:1 tokens on supply,
/// pro-rata value on redeem, owner knobs to inject yield (revenue) and loss
/// (the first-loss event that defines this venue class). The concrete venue
/// found by per-name DD implements the same ICreditPool surface.
contract MockCreditPool {
    IERC20 public immutable usdc;
    uint256 public totalTokens;
    uint256 public totalValue; // mark-to-model pool value in underlying units
    mapping(address => uint256) public tokens;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function supply(uint256 assets, address onBehalf) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), assets);
        tokens[onBehalf] += assets; // 1:1 at entry
        totalTokens += assets;
        totalValue += assets;
        return assets;
    }

    function redeem(uint256 t, address receiver) external returns (uint256) {
        require(!breakRedeem, "pool: locked");
        uint256 bal = tokens[msg.sender];
        require(t <= bal, "pool: tokens");
        uint256 assets = totalTokens == 0 ? 0 : (t * totalValue) / totalTokens; // pro-rata
        tokens[msg.sender] = bal - t;
        totalTokens -= t;
        totalValue -= assets;
        usdc.transfer(receiver, assets);
        return assets;
    }

    function positionValue(address who) external view returns (uint256) {
        return totalTokens == 0 ? 0 : (tokens[who] * totalValue) / totalTokens;
    }

    function positionTokens(address who) external view returns (uint256) {
        return tokens[who];
    }

    /*//////////////////// test knobs ////////////////////*/

    function injectYieldBps(uint256 bps) external {
        totalValue += (totalValue * bps) / 10000;
    }

    function injectLossBps(uint256 bps) external {
        totalValue -= (totalValue * bps) / 10000;
    }

    /// When set, redeems revert — simulates a locked/illiquid pool (queue,
    /// window, or the venue's own breaker). The adapter must partial-no-op.
    bool public breakRedeem;

    function setBreakRedeem(bool on) external {
        breakRedeem = on;
    }
}
