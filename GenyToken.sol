// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Geny
/// @author compez.eth
/// @notice ERC20 token with a total supply of 256 million, designed to empower creators and fuel boundless innovation within the Genyleap ecosystem.
/// @custom:security-contact security@genyleap.com

contract GenyToken is Initializable, ERC20Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {

    // === Constants ===

    /// @dev Total token supply (256 million tokens with 18 decimals)
    uint256 public constant TOTAL_SUPPLY = 256_000_000 * 10 ** 18;

    /// @dev Contract version for upgrade tracking
    uint256 public constant VERSION = 1;

    /// @dev Token name
    string public constant TOKEN_NAME = "Genyleap";

    /// @dev Token symbol
    string public constant TOKEN_SYMBOL = "GENY";

    // === State Variables ===

    /// @dev Total amount of tokens burned
    uint256 public totalSupplyBurned;

    /// @dev Last timestamp when a burn occurred
    uint256 public lastBurnTimestamp;

    /// @dev Last timestamp when a token recovery occurred
    uint256 public lastRecoveryTimestamp;

    /// @dev Cooldown period for burning and token recovery (default 24 hours)
    uint256 public cooldown;

    /// @dev Percentage limit for burn and recovery operations (default 10%, i.e., 1000 basis points)
    uint256 public limitBasisPoints;

    /// @dev Maximum number of recipients allowed in a single batch distribution (configurable, default 50)
    uint256 public maxBatchRecipients;

    // === Events ===

    /// @dev Emitted when the contract is initialized
    event Initialized(address indexed owner);

    /// @dev Emitted when tokens are distributed to a single recipient
    event TokensDistributed(address indexed recipient, uint256 amount);

    /// @dev Emitted when tokens are batch distributed
    event TokensDistributedBatch(address[] indexed recipients, uint256 indexed totalAmount);

    /// @dev Emitted when tokens are recovered with a reason
    event TokensRecovered(address indexed recipient, uint256 amount, string reason);

    /// @dev Emitted when tokens are burned with a reason
    event TokensBurned(address indexed burner, uint256 amount, uint256 indexed remainingSupply, string reason);

    /// @dev Emitted when the contract is paused
    event ContractPaused(address indexed pauser);

    /// @dev Emitted when the contract is unpaused
    event ContractUnpaused(address indexed unpauser);

    /// @dev Emitted when the burn/recovery limit is updated
    event LimitUpdated(uint256 indexed newLimitBasisPoints);

    /// @dev Emitted when the cooldown period is updated
    event CooldownUpdated(uint256 indexed newCooldown);

    /// @dev Emitted when the maximum batch recipients is updated
    event MaxBatchRecipientsUpdated(uint256 indexed newLimit);

    /// @dev Emitted when the contract is upgraded
    event Upgraded(address indexed newImplementation, uint256 indexed version);

    /// @dev Emitted when ETH is received
    event EthReceived(address indexed sender, uint256 amount);

    /// @dev Emitted when ETH is withdrawn with a reason
    event EthWithdrawn(address indexed recipient, uint256 amount, string reason);

    // === Constructor ===

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // === Custom Errors ===

    error ZeroAddress();
    error InvalidAmount();
    error BalanceOverflow();
    error ArraysLengthMismatch();
    error InvalidBatchSize();
    error ZeroAmount();
    error DuplicateRecipient();
    error InsufficientBalance();
    error CooldownActive();
    error ExceedsLimit();
    error InvalidRecipient();
    error EthTransferFailed();
    error InvalidLimit();
    error InvalidCooldown();
    error InvalidBatchLimit();
    error InvalidImplementation();
    
    // === Initializer ===

    /// @notice Initializes the token contract
    /// @param initialOwner Address to be set as the owner (must be a multisig like Gnosis Safe with 3/5 signatures)
    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();

        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __Ownable2Step_init();
        _transferOwnership(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _mint(address(this), TOTAL_SUPPLY);
        cooldown = 1 days; // Default 24 hours
        limitBasisPoints = 1000; // Default 10% (1000 basis points)
        maxBatchRecipients = 50; // Default maximum batch recipients

        emit Initialized(initialOwner);
    }

    // === External Functions ===

    /// @notice Distributes tokens to a single address
    /// @dev Ensures tokens are not locked in a pending state; requires contract to be unpaused
    /// @param recipient Address to receive tokens
    /// @param amount Amount of tokens to send
    function distribute(address recipient, uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        _validateRecipient(recipient);
        uint256 contractBalance = balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        if (amount > contractBalance) revert InvalidAmount();
        if (balanceOf(recipient) + amount > type(uint256).max) revert BalanceOverflow();

        _transfer(address(this), recipient, amount);
        emit TokensDistributed(recipient, amount);
    }

    /// @notice Distributes tokens to multiple addresses in a batch
    /// @dev Prevents Sybil attacks by checking for duplicate recipients; large distributions should use auxiliary contracts
    /// @param recipients List of recipient addresses
    /// @param amounts List of token amounts corresponding to each recipient
    function distributeBatch(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner nonReentrant whenNotPaused {
        uint256 len = recipients.length;
        if (len != amounts.length) revert ArraysLengthMismatch();
        if (len == 0 || len > maxBatchRecipients) revert InvalidBatchSize();

        uint256 totalAmount;
        uint256 contractBalance = balanceOf(address(this));
        // Check for duplicate recipients using a bitmap for efficiency
        uint256 bitmap;
        for (uint256 i = 0; i < len; i++) {
            address recipient = recipients[i];
            _validateRecipient(recipient);
            if (amounts[i] == 0) revert ZeroAmount();
            if (balanceOf(recipient) + amounts[i] > type(uint256).max) revert BalanceOverflow();
            // Use address as a simplified hash for bitmap (not perfect but sufficient for small batches)
            uint256 addrHash = uint256(uint160(recipient)) % 256;
            if ((bitmap & (1 << addrHash)) != 0) revert DuplicateRecipient();
            bitmap |= (1 << addrHash);
            totalAmount += amounts[i];
        }

        if (totalAmount > contractBalance) revert InsufficientBalance();

        for (uint256 i = 0; i < len; i++) {
            _transfer(address(this), recipients[i], amounts[i]);
        }

        emit TokensDistributedBatch(recipients, totalAmount);
    }

    /// @notice Recovers GENY tokens accidentally sent to the contract (e.g., user errors)
    /// @dev Callable only by owner, limited by limitBasisPoints (default 10%), configurable cooldown; includes reason for transparency
    /// @param recipient Address to receive the recovered tokens
    /// @param amount Number of tokens to recover
    /// @param reason Reason for the recovery (e.g., "User error", "Contract migration")
    function recoverTokens(address recipient, uint256 amount, string calldata reason) external onlyOwner nonReentrant {
        if (block.timestamp < lastRecoveryTimestamp + cooldown) revert CooldownActive();
        _validateRecipient(recipient);
        uint256 contractBalance = balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        if (amount > contractBalance) revert InvalidAmount();
        if (amount > (contractBalance * limitBasisPoints) / 10000) revert ExceedsLimit();

        _transfer(address(this), recipient, amount);
        lastRecoveryTimestamp = block.timestamp;
        emit TokensRecovered(recipient, amount, reason);
    }

    /// @notice Burns tokens from the contract balance in critical situations (e.g., hacks, unclaimed airdrop tokens, distribution errors)
    /// @dev Callable only by owner, limited by limitBasisPoints (default 10%), configurable cooldown; includes reason for transparency
    /// @param amount Number of tokens to burn
    /// @param reason Reason for the burn (e.g., "Unclaimed airdrop", "Error correction")
    function burn(uint256 amount, string calldata reason) external onlyOwner nonReentrant whenNotPaused {
        if (block.timestamp < lastBurnTimestamp + cooldown) revert CooldownActive();
        uint256 contractBalance = balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        if (amount > contractBalance) revert InvalidAmount();
        if (amount > (contractBalance * limitBasisPoints) / 10000) revert ExceedsLimit();

        _burn(address(this), amount);
        totalSupplyBurned += amount;
        lastBurnTimestamp = block.timestamp;
        emit TokensBurned(msg.sender, amount, totalSupply(), reason);
    }

    /// @notice Burns tokens without percentage limit in emergency situations
    /// @dev Callable only by owner, bypasses limitBasisPoints for critical cases; includes reason for transparency
    /// @param amount Number of tokens to burn
    /// @param reason Reason for the emergency burn (e.g., "Critical error", "Supply adjustment")
    function emergencyBurn(uint256 amount, string calldata reason) external onlyOwner nonReentrant whenNotPaused {
        if (block.timestamp < lastBurnTimestamp + cooldown) revert CooldownActive();
        uint256 contractBalance = balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        if (amount > contractBalance) revert InvalidAmount();

        _burn(address(this), amount);
        totalSupplyBurned += amount;
        lastBurnTimestamp = block.timestamp;
        emit TokensBurned(msg.sender, amount, totalSupply(), reason);
    }

    /// @notice Withdraws ETH from the contract balance
    /// @dev Callable only by owner, ensures ETH is not locked in the contract; includes reason for transparency
    /// @param recipient Address to receive the ETH
    /// @param amount Amount of ETH to withdraw (in wei)
    /// @param reason Reason for the withdrawal (e.g., "Contract maintenance", "Error recovery")
    function withdrawEth(address payable recipient, uint256 amount, string calldata reason) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (amount > address(this).balance) revert InvalidAmount();

        // Checks-Effects-Interactions pattern
        (bool sent, ) = recipient.call{value: amount}("");
        if (!sent) revert EthTransferFailed();

        emit EthWithdrawn(recipient, amount, reason);
    }

    /// @notice Updates the burn and recovery limit (in basis points, e.g., 1000 = 10%)
    /// @dev Callable only by owner, limit must be between 1% and 50% to prevent supply volatility; emits LimitUpdated event
    /// @param newLimitBasisPoints New limit in basis points (100 = 1%, 5000 = 50%)
    function updateLimit(uint256 newLimitBasisPoints) external onlyOwner {
        if (newLimitBasisPoints < 100 || newLimitBasisPoints > 5000) revert InvalidLimit();
        limitBasisPoints = newLimitBasisPoints;
        emit LimitUpdated(newLimitBasisPoints);
    }

    /// @notice Updates the cooldown period for burn and recovery operations
    /// @dev Callable only by owner, cooldown must be between 1 hour and 7 days; emits CooldownUpdated event
    /// @param newCooldown New cooldown period in seconds
    function setCooldown(uint256 newCooldown) external onlyOwner {
        if (newCooldown < 1 hours || newCooldown > 7 days) revert InvalidCooldown();
        cooldown = newCooldown;
        emit CooldownUpdated(newCooldown);
    }

    /// @notice Sets the maximum number of recipients allowed in a single batch distribution
    /// @dev Callable only by owner; new limit must be between 10 and 500 to balance gas costs and functionality
    /// @param newLimit The new maximum number of recipients
    function setMaxBatchRecipients(uint256 newLimit) external onlyOwner {
        if (newLimit < 10 || newLimit > 500) revert InvalidBatchLimit();
        maxBatchRecipients = newLimit;
        emit MaxBatchRecipientsUpdated(newLimit);
    }

    /// @notice Pauses the contract (emergency stop)
    /// @dev Only callable by owner; emits ContractPaused event
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by owner; emits ContractUnpaused event
    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Returns contract's token balance
    /// @return Balance of tokens held by the contract
    function getContractBalance() external view returns (uint256) {
        return balanceOf(address(this));
    }

    /// @notice Returns circulating supply (TOTAL_SUPPLY - contract balance)
    /// @return Circulating supply
    function getCirculatingSupply() external view returns (uint256) {
        return TOTAL_SUPPLY - balanceOf(address(this));
    }

    /// @notice Returns total amount of burned tokens
    /// @return Total amount of tokens burned
    function getTotalSupplyBurned() external view returns (uint256) {
        return totalSupplyBurned;
    }

    // === Internal Functions ===

    /// @dev Authorizes the contract upgrade
    /// @dev Only callable by owner; ensures new implementation complies with existing restrictions
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert InvalidImplementation();
        uint256 codeSize;
        assembly { codeSize := extcodesize(newImplementation) }
        if (codeSize == 0) revert InvalidImplementation();
        emit Upgraded(newImplementation, VERSION);
    }

    /// @dev Validates a recipient address, preventing unauthorized or risky addresses
    /// @param recipient Address to validate
    function _validateRecipient(address recipient) private view {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this)) revert InvalidRecipient();
        uint256 codeSize;
        assembly { codeSize := extcodesize(recipient) }
        if (codeSize != 0 && recipient != owner()) revert InvalidRecipient();
    }

    // === Public Overrides ===

    /// @notice Overrides transfer to respect paused state
    /// @param recipient Address to send tokens to
    /// @param amount Amount of tokens to transfer
    /// @return bool Success status
    function transfer(address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transfer(recipient, amount);
    }

    /// @notice Overrides approve to respect paused state
    /// @param spender Address allowed to spend tokens
    /// @param amount Amount of tokens to approve
    /// @return bool Success status
    function approve(address spender, uint256 amount) public override whenNotPaused returns (bool) {
        return super.approve(spender, amount);
    }

    /// @notice Overrides transferFrom to respect paused state
    /// @param sender Address sending tokens
    /// @param recipient Address receiving tokens
    /// @param amount Amount of tokens to transfer
    /// @return bool Success status
    function transferFrom(address sender, address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }

    // === Fallback ===

    /// @notice Fallback to receive ETH
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}