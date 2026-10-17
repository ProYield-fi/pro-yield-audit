// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test stand-in for an Aave v4 USDC **Tokenization Spoke**
/// (`waPrimeUSDC` / `waCoreUSDC`) — a synchronous ERC-4626 wrapper over USDC
/// whose exit is LIQUIDITY-CONDITIONAL, mirroring the reviewed spoke behavior
/// (`docs/AAVE_DD.md` §5):
///   - `maxDeposit` is bounded by the per-spoke ADD CAP (and 0 when halted);
///   - `maxWithdraw`/`maxRedeem` are bounded by the Hub's UN-BORROWED USDC
///     (`getAssetLiquidity`, modeled here by the `liquidity` knob) and are 0
///     while the spoke is halted / the reserve is paused;
///   - `redeem` reverts outside those caps (the Hub's `remove` reverts when the
///     requested assets exceed available liquidity).
///
/// NOTE ON `halted`: the REAL spoke exposes no `halted()` getter (verified live
/// 2026-10-15 — `halted()`/`active()`/`isHalted()`/`paused()` all revert on
/// `0x486415fb…Cb31`). The halt is OBSERVABLE only through the ERC-4626 caps
/// going to 0 (`maxDeposit`/`maxRedeem`/`maxWithdraw`) and through the Hub
/// balance. The knob here models that state so the adapter's degradation can be
/// pinned; production monitoring reads the caps, not a flag.
contract MockAaveSpoke is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken; // USDC
    uint256 public yieldAccrued; // paper value above real holdings (interest)
    uint256 public addCap = type(uint256).max; // per-spoke add cap (totalAssets bound)
    uint256 public liquidity = type(uint256).max; // Hub un-borrowed USDC (exit depth)
    bool public halted;
    uint256 public assetId;
    address public hub;

    constructor(IERC20 usdc, uint256 _assetId) ERC20("Wrapped Aave Prime USDC", "waPrimeUSDC") {
        assetToken = usdc;
        assetId = _assetId;
    }

    // ------------------------------------------------------------- ERC-4626

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function decimals() public pure override returns (uint8) {
        return 6; // USDC — the wrapper mirrors its asset's decimals (live read)
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

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function maxDeposit(address) public view returns (uint256) {
        if (halted) return 0; // paused spoke: no ads
        uint256 ta = totalAssets();
        return addCap > ta ? addCap - ta : 0;
    }

    function maxMint(address) external view returns (uint256) {
        return convertToShares(maxDeposit(address(0)));
    }

    /// @notice Hub-liquidity-capped, halt-aware — the venue's real exit rule.
    function maxWithdraw(address owner) public view returns (uint256) {
        if (halted) return 0;
        uint256 bal = convertToAssets(balanceOf(owner));
        return bal > liquidity ? liquidity : bal;
    }

    function maxRedeem(address owner) public view returns (uint256) {
        if (halted) return 0;
        uint256 shares = balanceOf(owner);
        // unlimited liquidity = no cap (guards the 256-bit multiply below)
        if (liquidity >= totalAssets()) return shares;
        uint256 byLiquidity = convertToShares(liquidity);
        return shares > byLiquidity ? byLiquidity : shares;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(!halted, "spoke: halted");
        require(assets <= maxDeposit(receiver), "spoke: add cap");
        shares = convertToShares(assets);
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(!halted, "spoke: halted");
        assets = convertToAssets(shares);
        require(assets <= maxDeposit(receiver), "spoke: add cap");
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(!halted, "spoke: halted");
        uint256 allowed = maxWithdraw(owner);
        require(assets <= allowed, "spoke: liquidity");
        shares = convertToShares(assets);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        assetToken.safeTransfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(!halted, "spoke: halted");
        require(shares <= maxRedeem(owner), "spoke: liquidity");
        assets = convertToAssets(shares);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        // real holdings bound the payout; paper yield is burned away first
        uint256 paid = assets > assetToken.balanceOf(address(this)) ? assetToken.balanceOf(address(this)) : assets;
        if (assets > paid) yieldAccrued = yieldAccrued > (assets - paid) ? yieldAccrued - (assets - paid) : 0;
        assetToken.safeTransfer(receiver, paid);
    }

    // ----------------------------------------------------------- test knobs

    function setAddCap(uint256 cap) external {
        addCap = cap;
    }

    /// @notice Set the Hub's available (un-borrowed) USDC — the exit depth.
    function setLiquidity(uint256 amount) external {
        liquidity = amount;
    }

    function setHalted(bool h) external {
        halted = h;
    }

    function setHub(address h) external {
        hub = h;
    }

    /// @notice Accrue REAL interest: mint USDC into the wrapper (PPS rises).
    function injectBackingUsdc(uint256 amount) external {
        MockAaveSpokeMint(address(assetToken)).mint(address(this), amount);
    }

    /// @notice A real Hub deficit: burn real USDC holdings (PPS falls).
    function removeBackingUsdc(uint256 amount) external {
        assetToken.safeTransfer(address(0xdead), amount);
    }
}

/// @dev minimal mint hook so the mock can faucet its own underlying
interface MockAaveSpokeMint {
    function mint(address to, uint256 amount) external;
}
