// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title GenyToken
/// @author compez.eth
/// @notice An ERC20 token with a fixed supply of 256 million, designed to empower creators and drive innovation in the Genyleap ecosystem.
/// @dev Extends OpenZeppelin's ERC20 with burnable functionality, permit for gasless approvals, votes for decentralized governance,
///      ownership for centralized control, and pausability for emergency stops. All allocations are handled by an external contract.
///      Emits standard ERC20 events (Transfer, Approval) and ERC20Votes events (DelegateChanged, DelegateVotesChanged).
///      Ownership and pausability add security features. Optimized for gas with payable functions and custom events.
///      Integrates with GenyGuard for advanced self-custody protection without core dependency.
/// @custom:security-contact security@genyleap.com
interface IGenyGuard {
    function isRecoveryModeActive(address user) external view returns (bool);
    function getRecoveryWallet(address user) external view returns (address);
}

contract GenyToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes, ERC20Pausable, Ownable2Step {
    /// @dev Fixed total token supply (256 million tokens with 18 decimals)
    uint256 internal constant _TOTAL_SUPPLY = 2.56e8 * 1e18;

    /// @dev Cached token name as string for ERC20 compatibility and gas optimization
    string private _tokenNameStr;

    /// @dev Cached token symbol as string for ERC20 compatibility and gas optimization
    string private _tokenSymbolStr;

    /// @dev Metadata URI for the token, compliant with ERC-7572
    string private _contractURI;

    /// @notice Reference to GenyGuard contract for recovery enforcement
    address public immutable genyGuard;

    /// @notice Emitted once upon successful token deployment and initial allocation
    event Initialized(address indexed allocationContract, uint256 amount);

    /// @notice Emitted when token name and symbol are set during deployment
    event TokenMetadataSet(string indexed name, string indexed symbol);

    /// @notice Emitted when the contract metadata URI is set during deployment
    event ContractURISet(string indexed uri);

    /// @notice Emitted for every transfer, including delegate votes change
    event TransferWithVotes(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when the contract is paused
    event PausedBy(address indexed owner);

    /// @notice Emitted when the contract is unpaused
    event UnpausedBy(address indexed owner);

    /// @dev Custom error for zero address validation
    error ZeroAddressNotAllowed();

    /// @dev Custom error for empty URI validation
    error URIMustBeSet();

    /// @notice Deploys the token and allocates the total supply to the specified contract
    /// @dev Initializes token metadata and mints the fixed supply to the allocation contract. Payable to save gas.
    /// @param allocationContract Address to receive the initial token supply and become the owner
    /// @param contractURI_ Metadata URI for the token (ERC-7572)
    /// @param genyGuard_ Address of GenyGuard contract
    constructor(
        address allocationContract,
        string memory contractURI_,
        address genyGuard_
    ) ERC20("Genyleap", "GENY") ERC20Permit("Genyleap") Ownable(address(this)) payable {
        if (allocationContract == address(0)) revert ZeroAddressNotAllowed();
        if (bytes(contractURI_).length == 0) revert URIMustBeSet();
        genyGuard = genyGuard_;
        _transferOwnership(allocationContract);

        _tokenNameStr = "Genyleap";
        _tokenSymbolStr = "GENY";
        emit TokenMetadataSet(_tokenNameStr, _tokenSymbolStr);

        _contractURI = contractURI_;
        emit ContractURISet(_contractURI);

        uint256 totalSupply = _TOTAL_SUPPLY;
        _mint(allocationContract, totalSupply);
        emit Initialized(allocationContract, totalSupply);
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

    /// @dev Updates token state for transfers, including vote tracking, pausability, and recovery guard
    /// @param from Address sending the tokens
    /// @param to Address receiving the tokens
    /// @param amount Number of tokens transferred
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes, ERC20Pausable)
    {
        // Enforce recovery: if from is in recovery mode, only allow to recovery wallet
        if (from != address(0) && from != to && IGenyGuard(genyGuard).isRecoveryModeActive(from)) {
            require(
                to == IGenyGuard(genyGuard).getRecoveryWallet(from),
                "Recovery: only to recovery wallet"
            );
        }
        super._update(from, to, amount);
        emit TransferWithVotes(from, to, amount);
    }

    /// @notice Pauses all token transfers and burns
    /// @dev Only callable by owner. Payable to save gas.
    function pause() external onlyOwner payable {
        _pause();
        emit PausedBy(msg.sender);
    }

    /// @notice Unpauses all token transfers and burns
    /// @dev Only callable by owner. Payable to save gas.
    function unpause() external onlyOwner payable {
        _unpause();
        emit UnpausedBy(msg.sender);
    }

    /// @notice No-op inheritance fix to enable permit and votes functionality with shared nonce behavior
    /// @dev Overrides OpenZeppelin function to resolve ERC20Permit and Nonces inheritance conflict.
    /// @param owner Address to retrieve the nonce for
    /// @return The current nonce for the specified owner
    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
