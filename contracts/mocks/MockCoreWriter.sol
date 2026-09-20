// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Records CoreWriter actions for byte-exact assertions in tests.
/// Deployed normally, then copied (anvil_setCode) to 0x3333...3333 so the
/// adapter's constant CORE_WRITER resolves to it. Read state by calling the
/// mock's ABI AT the fixed address (storage lives there).
contract MockCoreWriter {
    bytes public lastAction;
    uint256 public actionCount;

    function sendRawAction(bytes calldata data) external {
        lastAction = data;
        actionCount += 1;
    }
}

/// @notice Records USDC EVM→Core deposits. Copied to the CoreDepositWallet
/// address (chainid 998 → testnet constant) via anvil_setCode.
/// If `token` is set, deposit() actually pulls funds (realistic balances).
contract MockCoreDepositWallet {
    address public token;
    uint256 public lastAmount;
    uint32 public lastDex;
    uint256 public depositCount;

    function setToken(address token_) external {
        token = token_;
    }

    function deposit(uint256 amount, uint32 destinationDex) external {
        lastAmount = amount;
        lastDex = destinationDex;
        depositCount += 1;
        if (token != address(0)) {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }
}
