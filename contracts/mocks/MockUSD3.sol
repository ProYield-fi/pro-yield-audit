// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Minimal ERC-4626 test stand-in for 3Jane USD3 (senior tranche over
/// USDC, 6dp like its underlying). Knobs: yield accrual and mark-down (the
/// senior can also take losses through the waterfall in extreme scenarios).
/// The REAL USD3 is a Yearn-curated ERC-4626 with the same standard surface
/// (asset/deposit/withdraw/redeem/max*/preview*/convertTo*).
abstract contract ERC4626MockCore is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    uint256 public yieldAccrued; // knob-driven extra value on top of holdings

    constructor(IERC20 _asset, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        assetToken = _asset;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view virtual returns (uint256) {
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

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
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
        uint256 payableAmt = assets > assetToken.balanceOf(address(this)) ? assetToken.balanceOf(address(this)) : assets;
        _burn(owner, shares);
        // yieldAccrued absorbed first (paper value above real holdings is
        // redeemed against the knob, mirroring "yield absorbs losses first")
        yieldAccrued = yieldAccrued > (assets - payableAmt) ? yieldAccrued - (assets - payableAmt) : 0;
        assetToken.safeTransfer(receiver, payableAmt);
    }

    /// knob: drain the vault's USDC holdings (simulate the cash buffer leaving)
    function drainUsdc(uint256 amount, address to) external {
        assetToken.transfer(to, amount);
    }

    /*//////////////////// real-yield helpers (for lifecycle tests) ////////////////////*/

    /// mint USD3 shares to `to` WITHOUT backing — pairs with injectBackingUsdc
    function faucetMintUsd3(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// mint real USDC into the vault (pool income arriving) — keeps PPS honest
    /// when paired with a faucetMintUsd3 of amount / PPS
    function injectBackingUsdc(uint256 amount) external {
        MockUSDC(address(assetToken)).mint(address(this), amount);
    }
}

contract MockUSD3 is ERC4626MockCore {
    constructor(IERC20 usdc) ERC4626MockCore(usdc, "Mock USD3", "USD3m") {}

    /// knob: accrue yield (senior share of pool income)
    function injectYieldBps(uint256 bps) external {
        yieldAccrued += (totalAssets() * bps) / 10000;
    }

    /// knob: mark the senior DOWN (great-crisis-class correlated stress).
    /// Loss = bps of total value; absorbed by paper yield first, then by
    /// real holdings (burned to the void — value leaves the system).
    function injectLossBps(uint256 bps) external {
        uint256 loss = (totalAssets() * bps) / 10000;
        uint256 fromYield = yieldAccrued > loss ? loss : yieldAccrued;
        yieldAccrued -= fromYield;
        uint256 remaining = loss - fromYield;
        if (remaining > 0) {
            assetToken.transfer(address(0xdead), remaining);
        }
    }
}
