// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title GenyToken
/// @author compez.eth
/// @notice An ERC20 token with a fixed supply of 256 million, designed to empower creators and drive innovation in the Genyleap ecosystem.
/// @dev Extends OpenZeppelin's ERC20 with permit for gasless approvals and votes for decentralized governance. All tokens are minted to the contract itself, with allocations handled by external contracts. Emits standard ERC20 events (Transfer, Approval) and ERC20Votes events (DelegateChanged, DelegateVotesChanged) for key operations; additional events (e.g., for permit) are not defined as standard Approval events suffice for off-chain tracking, given the fixed supply and external allocation. Nonces import is required for ERC20Permit to manage gasless approvals via signatures.
/// @custom:security-contact security@genyleap.com
contract GenyToken is ERC20, ERC20Permit, ERC20Votes {
    /// @dev Custom error for empty URI validation
    error URIMustBeSet();

    /// @dev Fixed total token supply (256 million tokens with 18 decimals)
    uint256 internal constant _TOTAL_SUPPLY = 2.56e8 * 1e18;

    /// @dev Cached token name as string for ERC20 compatibility and gas optimization
    string private _tokenNameStr;

    /// @dev Cached token symbol as string for ERC20 compatibility and gas optimization
    string private _tokenSymbolStr;

    /// @dev Metadata URI for the token, compliant with ERC-7572
    string private _contractURI;

    /// @notice Emitted once upon successful token deployment and initial allocation
    /// @param contractAddress Address of this contract where tokens are minted
    /// @param amount Total number of tokens minted
    event Initialized(address indexed contractAddress, uint256 amount);

    /// @notice Emitted when token name and symbol are set during deployment
    /// @param name The token name set, indexed for efficient off-chain filtering
    /// @param symbol The token symbol set, indexed for efficient off-chain filtering
    event TokenMetadataSet(string indexed name, string indexed symbol);

    /// @notice Emitted when the contract metadata URI is set during deployment
    /// @param uri The metadata URI set, indexed for efficient off-chain filtering
    event ContractURISet(string indexed uri);

    /// @notice Emitted for every transfer, including delegate votes change
    /// @param from Address sending the tokens
    /// @param to Address receiving the tokens
    /// @param amount Number of tokens transferred
    event TransferWithVotes(address indexed from, address indexed to, uint256 amount);

    /// @notice Deploys the token and mints the total supply to the contract itself
    /// @dev Initializes token metadata and mints the fixed supply to this contract. Not payable to prevent ETH deposits and potential locking, prioritizing security over minor gas savings. Uses custom errors for gas-efficient error handling. Emits events for state changes (TokenMetadataSet, ContractURISet, Initialized).
    /// @param contractURI_ Metadata URI for the token (ERC-7572)
    constructor(string memory contractURI_) ERC20("Genyleap", "GENY") ERC20Permit("Genyleap") {
        if (bytes(contractURI_).length == 0) {
            revert URIMustBeSet();
        }

        // Cache address(this) for gas optimization
        address self = address(this);

        // Set token name and symbol (for external view functions)
        _tokenNameStr = "Genyleap";
        _tokenSymbolStr = "GENY";
        emit TokenMetadataSet(_tokenNameStr, _tokenSymbolStr);

        // Set metadata URI and emit event
        _contractURI = contractURI_;
        emit ContractURISet(contractURI_);

        // Mint the fixed supply to this contract
        uint256 totalSupply = _TOTAL_SUPPLY;
        _mint(self, totalSupply);
        emit Initialized(self, totalSupply);
    }

    /// @notice Returns the contract metadata URI (ERC-7572)
    /// @return The metadata URI as a string
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Returns the fixed total supply of the token
    /// @return The total supply in wei (256 million tokens with 18 decimals)
    function totalSupplyConstant() external pure returns (uint256) {
        return _TOTAL_SUPPLY;
    }

    /// @inheritdoc ERC20
    /// @notice Returns the token name as expected by ERC20 interface
    function name() public view override returns (string memory) {
        return _tokenNameStr;
    }

    /// @inheritdoc ERC20
    /// @notice Returns the token symbol as expected by ERC20 interface
    function symbol() public view override returns (string memory) {
        return _tokenSymbolStr;
    }

    /// @dev Updates token state for transfers, including vote tracking
    /// @param from Address sending the tokens
    /// @param to Address receiving the tokens
    /// @param amount Number of tokens transferred
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
        // Emit custom transfer event for tracking votes
        emit TransferWithVotes(from, to, amount);
    }

    /// @notice No-op inheritance fix to enable permit and votes functionality with shared nonce behavior
    /// @dev Overrides OpenZeppelin function to resolve ERC20Permit and Nonces inheritance conflict. Visibility set to public to match parent contracts.
    /// @param owner Address to retrieve the nonce for
    /// @return The current nonce for the specified owner
    function nonces(address owner)
        public
        view
        virtual
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}