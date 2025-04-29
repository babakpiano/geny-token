// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/// @title Geny
/// @author compez.eth
/// @notice ERC20 token with a total supply of 256 million, designed to empower creators and fuel boundless innovation within the Genyleap ecosystem.
/// @dev Implements core ERC20 functionality with permit for gasless approvals and votes for decentralized governance. All allocations and sensitive operations are handled by auxiliary contracts.
/// @custom:security-contact security@genyleap.com
contract GenyToken is ERC20, ERC20Permit, ERC20Votes {
    /// @dev Total token supply (256 million tokens with 18 decimals)
    uint256 internal constant _TOTAL_SUPPLY = 256_000_000 * 10 ** 18;

    /// @dev Token name and symbol as bytes32 for gas optimization
    bytes32 internal constant _TOKEN_NAME = bytes32("Genyleap");
    bytes32 internal constant _TOKEN_SYMBOL = bytes32("GENY");

    /// @dev Cached token name and symbol as strings for gas optimization
    string private _tokenNameStr;
    string private _tokenSymbolStr;

    /// @notice Metadata URI (ERC-7572)
    string private _contractURI;

    /// @notice Emitted once upon successful token deployment and allocation
    event Initialized(address indexed allocationContract, uint256 amount);

    /// @notice Token deployment and supply allocation
    /// @param allocationContract Recipient address of the initial supply
    /// @param contractURI_ Metadata URI for the token
    constructor(
        address allocationContract,
        string memory contractURI_
    ) payable ERC20(_tokenNameStr, _tokenSymbolStr) ERC20Permit(_tokenNameStr) {
        require(msg.value == 0, "ETH not accepted");
        require(allocationContract != address(0), "Zero address not allowed");
        require(bytes(contractURI_).length != 0, "URI must be set");

        uint256 totalSupply = _TOTAL_SUPPLY; // Cache the total supply in memory
        _tokenNameStr = _bytes32ToString(_TOKEN_NAME); // Cache name
        _tokenSymbolStr = _bytes32ToString(_TOKEN_SYMBOL); // Cache symbol

        _contractURI = contractURI_;
        _mint(allocationContract, totalSupply);

        emit Initialized(allocationContract, totalSupply);
    }

    /// @notice Contract metadata URI
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Returns fixed total supply
    function totalSupplyConstant() external pure returns (uint256) {
        return _TOTAL_SUPPLY;
    }

    /// @notice Returns token name
    function tokenName() external view returns (string memory) {
        return _tokenNameStr;
    }

    /// @notice Returns token symbol
    function tokenSymbol() external view returns (string memory) {
        return _tokenSymbolStr;
    }

    /// @dev Converts bytes32 to string for compatibility with ERC20 interfaces
    function _bytes32ToString(bytes32 _bytes) internal pure returns (string memory) {
        uint256 i = 0;
        while (i < 32 && _bytes[i] != 0) {
            unchecked { ++i; } // Optimized increment with unchecked
        }
        bytes memory bytesArray = new bytes(i);
        for (uint256 j = 0; j < i; ++j) {
            bytesArray[j] = _bytes[j];
        }
        return string(bytesArray);
    }

    /// @dev Hook for vote tracking
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    /// @dev Override for permit nonce handling (from ERC20Permit)
    function nonces(address owner)
        public
        view
        override(ERC20Permit)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
