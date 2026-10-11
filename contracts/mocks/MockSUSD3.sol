// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockUSD3} from "./MockUSD3.sol";

/// @notice Test stand-in for 3Jane sUSD3 (junior tranche, ERC-4626 over USD3,
/// 6dp) with the cooldown state machine MIRRORING the live ISUSD3 interface
/// (verified from source 2026-10-04):
///   startCooldown(shares) → {cooldownEnd = ts + cooldownDuration,
///   windowEnd = cooldownEnd + withdrawalWindow, shares} → redeem eligible
///   only inside the window; maxRedeem = eligible shares; cancelCooldown.
/// Knobs: junior share is levered — its own yield/loss on top of USD3's.
contract MockSUSD3 is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken; // USD3 (6dp)
    uint256 public yieldAccrued;
    uint256 public lockDuration = 0; // live value 2026-10-04 (retired lock)
    uint256 public cooldownDuration = 30 days; // live value [V]
    uint256 public withdrawalWindow = 36_525 days; // live value [V]

    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    mapping(address => UserCooldown) public cooldowns;

    event CooldownStarted(address indexed user, uint256 shares, uint256 timestamp);
    event CooldownCancelled(address indexed user);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);

    constructor(IERC20 usd3) ERC20("Mock sUSD3", "sUSD3m") {
        assetToken = usd3;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this)) + yieldAccrued;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function maxDeposit(address) external view returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external view returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Only cooldown-ELIGIBLE shares are withdrawable — the venue's
    /// core async-exit rule.
    function maxWithdraw(address owner) external view returns (uint256) {
        UserCooldown memory cd = cooldowns[owner];
        bool inWindow = block.timestamp >= cd.cooldownEnd && block.timestamp <= cd.windowEnd;
        uint256 eligible = inWindow ? cd.shares : 0;
        uint256 bal = balanceOf(owner);
        return eligible > bal ? bal : eligible;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return this.maxWithdraw(owner);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares); // ERC-4626 rule
        _redeem(shares, assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares); // ERC-4626 rule
        assets = convertToAssets(shares);
        _redeem(shares, assets, receiver, owner);
    }

    function _redeem(uint256 shares, uint256 assets, address receiver, address owner) internal {
        // the venue's own gate: only cooldown-eligible shares may leave
        uint256 allowed = this.maxWithdraw(owner);
        require(shares <= allowed, "sUSD3: cooldown");
        uint256 payableAmt = assets > assetToken.balanceOf(address(this)) ? assetToken.balanceOf(address(this)) : assets;
        _burn(owner, shares);
        // reduce the caller's cooldown book by the shares leaving
        UserCooldown storage cd = cooldowns[owner];
        uint128 remaining = uint128(cd.shares > shares ? cd.shares - shares : 0);
        cd.shares = remaining;
        yieldAccrued = yieldAccrued > (assets - payableAmt) ? yieldAccrued - (assets - payableAmt) : 0;
        assetToken.safeTransfer(receiver, payableAmt);
        emit WithdrawalCompleted(owner, shares, assets);
    }

    /*//////////////////// cooldown lifecycle (live semantics) ////////////////////*/

    function startCooldown(uint256 shares) external {
        require(balanceOf(msg.sender) >= shares, "sUSD3: balance");
        UserCooldown storage cd = cooldowns[msg.sender];
        require(_lockPassed(msg.sender), "sUSD3: locked");
        // accumulate shares; the timer restarts on a fresh start (close enough
        // to the live semantics for testing the ADAPTER's state machine)
        cd.shares = uint128(cd.shares + shares);
        cd.cooldownEnd = uint64(block.timestamp + cooldownDuration);
        cd.windowEnd = uint64(cd.cooldownEnd + withdrawalWindow);
        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }

    function cancelCooldown() external {
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

    function _lockPassed(address) internal view returns (bool) {
        return lockDuration == 0 || true; // live: lock retired; knob kept for parity
    }

    /*//////////////////// test knobs ////////////////////*/

    /// knob: the junior share is LEVERED — yield amplified vs the pool
    function injectJuniorYieldBps(uint256 bps) external {
        yieldAccrued += (totalAssets() * bps) / 10000;
    }

    /// knob: REAL junior yield — the pool pays the junior its levered share in
    /// actual USD3 tokens, with the USDC backing minted into the senior vault
    /// so the senior's PPS is not diluted (tranche-split income, honestly
    /// modeled). At a senior PPS of 1.0 the amounts are 1:1.
    function injectRealJuniorYieldUsd3(uint256 usd3Amount) external {
        MockUSD3 usd3Mock = MockUSD3(address(assetToken));
        usd3Mock.injectBackingUsdc(usd3Amount); // PPS 1.0 → backing equals tokens
        usd3Mock.faucetMintUsd3(address(this), usd3Amount);
    }

    /// knob: the junior tranche absorbs losses FIRST (the defining risk)
    function injectJuniorLossBps(uint256 bps) external {
        uint256 loss = (totalAssets() * bps) / 10000;
        uint256 fromYield = yieldAccrued > loss ? loss : yieldAccrued;
        yieldAccrued -= fromYield;
        uint256 remaining = loss - fromYield;
        if (remaining > 0) {
            assetToken.transfer(address(0xdead), remaining);
        }
    }
}
