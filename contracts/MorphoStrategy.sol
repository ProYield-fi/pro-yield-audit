// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
using SafeERC20 for IERC20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MorphoStrategy is BaseStrategy {
    address public morpho;
    uint256 public totalSupply;

    constructor(address _underlying, address _owner, address _morpho)
        BaseStrategy(_underlying, _owner, "Morpho")
    {
        morpho = _morpho;
    }

    function name() external view override returns (string memory) {
        return "Morpho";
    }

    function setMorpho(address _morpho) external onlyOwner nonReentrant {
        morpho = _morpho;
    }

    function supply(uint256 amount) external nonReentrant {
        require(morpho != address(0), "Morpho: not set");
        // Transfer underlying to Morpho
        underlying.safeTransferFrom(msg.sender, morpho, amount);
        totalSupply += amount;
    }

    function withdraw(uint256 amount) external override nonReentrant {
        totalSupply -= amount;
        underlying.safeTransfer(msg.sender, amount);
    }

    function _doHarvest() internal override returns (uint256) {
        uint256 profit = 0;
        if (morpho != address(0)) {
            // Harvest from Morpho by calling withdraw/supply cycle
            uint256 balance = underlying.balanceOf(address(this));
            if (balance > 0) {
                underlying.safeTransfer(morpho, balance);
                profit = balance;
            }
        }
        return profit;
    }
}
