// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Mock of the 0x811 borrowLendUserState precompile (mirrors the
/// hyper-evm-lib struct: BorrowLendUserTokenState { BasisAndValue borrow;
/// BasisAndValue supply } — all uint64). Return layout is the static tuple
/// (borrowBasis, borrowValue, supplyBasis, supplyValue) = 128 bytes.
/// Copied to 0x811 via anvil_setCode; the fallback asserts the real calldata
/// shape (address user, uint64 token) so a wrong encoding reverts in tests.
contract MockBorrowLendUserState {
    uint64 public borrowBasis;
    uint64 public borrowValue;
    uint64 public supplyBasis;
    uint64 public supplyValue;

    function set(uint64 bb, uint64 bv, uint64 sb, uint64 sv) external {
        borrowBasis = bb;
        borrowValue = bv;
        supplyBasis = sb;
        supplyValue = sv;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 64, "bad calldata shape (userState: address,uint64)");
        return abi.encode(borrowBasis, borrowValue, supplyBasis, supplyValue);
    }
}

/// @notice Stands in for a failing precompile (eth_call reverts).
contract MockAlwaysRevert {
    fallback(bytes calldata) external returns (bytes memory) {
        revert("mock precompile failure");
    }
}
