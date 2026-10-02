// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// HLEarnLib — byte-exact vectors for CoreWriter action 15 (borrow/lend).
// Byte layout: [01][00 00 0f] | word(op) | word(token) | word(wei)  → 100 bytes.
// The full-hex vector is hardcoded (computed independently of this library);
// the _expected() helper builds the same bytes via a different encoding path
// (packed uint256 words + fixed header literal) so a regression cannot
// self-validate.

import {Test} from "forge-std/Test.sol";
import {HLEarnLib} from "../../contracts/adapters/HLEarnLib.sol";

contract HLEarnLibTest is Test {
    function test_supply_usdc_fullhex_vector() public pure {
        assertEq(
            HLEarnLib.encodeSupply(0, 100_000_000),
            hex"0100000f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005f5e100"
        );
    }

    function test_supply_various() public pure {
        assertEq(HLEarnLib.encodeSupply(0, 0), _expected(0, 0, 0));
        assertEq(HLEarnLib.encodeSupply(0, 1_200_000_000), _expected(0, 0, 1_200_000_000));
        assertEq(HLEarnLib.encodeSupply(360, 42), _expected(0, 360, 42)); // non-USDC reserve passes through
    }

    function test_withdraw() public pure {
        assertEq(HLEarnLib.encodeWithdrawMax(0), _expected(1, 0, 0));
        assertEq(HLEarnLib.encodeWithdraw(0, 12_345_678), _expected(1, 0, 12_345_678));
    }

    function test_header_and_length() public pure {
        bytes memory d = HLEarnLib.encodeSupply(0, 1);
        assertEq(d.length, 100);
        assertEq(uint8(d[0]), 1); // encoding version
        assertEq(uint8(d[1]), 0);
        assertEq(uint8(d[2]), 0);
        assertEq(uint8(d[3]), 0x0f); // action id 15, big-endian
    }

    /// @dev Independent construction: header literal + three packed uint256 words.
    function _expected(uint256 op, uint256 tok, uint256 weiAmount) private pure returns (bytes memory) {
        return abi.encodePacked(hex"0100000f", op, tok, weiAmount);
    }
}
