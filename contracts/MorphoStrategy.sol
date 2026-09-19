// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
using SafeERC20 for IERC20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MorphoStrategy is BaseStrategy {
    address public morpho;
    uint256 public totalSupply;

    constructor(address _underlying, address initialOwner, address _morpho)
        BaseStrategy(_underlying, initialOwner, "Morpho")
    {
        require(_morpho != address(0), "Morpho: zero morpho");
        morpho = _morpho;
    }

    function name() external view override returns (string memory) {
        return "Morpho";
    }

    function setMorpho(address morpho_) external onlyOwner nonReentrant {
        require(morpho_ != address(0), "Morpho: zero morpho");
        morpho = morpho_;
    }

    function supply(uint256 amount) external nonReentrant {
        require(amount > 0, "Morpho: zero amount");
        require(morpho != address(0), "Morpho: not set");
        underlying.safeTransferFrom(msg.sender, morpho, amount);
        totalSupply += amount;
    }

    function withdraw(uint256 amount) external override nonReentrant {
        require(amount > 0, "Morpho: zero amount");
        require(totalSupply >= amount, "Morpho: insufficient supply");
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
