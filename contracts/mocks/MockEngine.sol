// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Mock 6dp USDC for tests.
contract MockUSDC6 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Mock HL Earn engine mirroring the REAL vault-facing API (BaseStrategy/HLEarnStrategy):
///   - totalAssets() = EVM balance + unsettled Core profit
///   - harvest()     = vault-only: sweeps realized profit as REAL USDC to the vault
///   - recall(a)     = vault-only: pays EVM idle balance to the vault (capped)
contract MockEngine {
    IERC20 public usdc;
    uint256 public profit;      // unsettled Core-side profit (USDC)
    address public vault;

    constructor(address _usdc) { usdc = IERC20(_usdc); }

    function setVault(address v) external { vault = v; }

    /// Simulate Core-side profit: book as unsettled profit (totalAssets = balance + profit).
    function setProfit(uint256 p) external { profit += p; }

    /// Simulate a loss: burn real USDC out of the engine's EVM balance.
    function setLoss(uint256 l) external { usdc.transfer(address(0xdead), l); }

    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this)) + profit;
    }

    function harvest() external returns (uint256 swept) {
        require(msg.sender == vault, "MockEngine: not vault");
        if (failHarvest) revert("MockEngine: harvest down");
        swept = profit;
        if (swept > 0) {
            profit = 0;
            MockUSDC6(address(usdc)).mint(address(this), swept); // Core profit arrives as real USDC
            usdc.transfer(msg.sender, swept);
        }
    }

    bool public failHarvest;
    function setFailHarvest(bool f) external { failHarvest = f; }

    function recall(uint256 amount) external {
        require(msg.sender == vault, "MockEngine: not vault");
        uint256 bal = usdc.balanceOf(address(this));
        usdc.transfer(msg.sender, amount > bal ? bal : amount);
    }
}