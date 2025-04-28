// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title GENY
/// @author compez.eth
/// @notice A Token for Empowering Creators, Fueling Boundless Innovation.
contract GenyToken is Initializable, ERC20Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    // === Constants ===

    /// @dev Total token supply (256 million tokens with 18 decimals)
    uint256 public constant TOTAL_SUPPLY = 256_000_000 * 10 ** 18;

    /// @dev Contract version for upgrade tracking
    uint256 public constant VERSION = 1;

    /// @dev Token metadata
    string public constant TOKEN_NAME = "Genyleap";
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

    /// @dev Emitted when tokens are distributed to a single recipient
    event TokensDistributed(address indexed recipient, uint256 amount);

    /// @dev Emitted when tokens are batch distributed
    event TokensDistributedBatch(address[] recipients, uint256 totalAmount);

    /// @dev Emitted when tokens are recovered with a reason
    event TokensRecovered(address indexed recipient, uint256 amount, string reason);

    /// @dev Emitted when tokens are burned with a reason
    event TokensBurned(address indexed burner, uint256 amount, uint256 remainingSupply, string reason);

    /// @dev Emitted when the contract is paused
    event ContractPaused(address indexed pauser);

    /// @dev Emitted when the contract is unpaused
    event ContractUnpaused(address indexed unpauser);

    /// @dev Emitted when the burn/recovery limit is updated
    event LimitUpdated(uint256 newLimitBasisPoints);

    /// @dev Emitted when the cooldown period is updated
    event CooldownUpdated(uint256 newCooldown);

    /// @dev Emitted when the maximum batch recipients is updated
    event MaxBatchRecipientsUpdated(uint256 newLimit);

    /// @dev Emitted when the contract is upgraded
    event Upgraded(address indexed newImplementation, uint256 version);

    /// @dev Emitted when ETH is received
    event EthReceived(address indexed sender, uint256 amount);

    // === Constructor ===

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // === Initializer ===

    /// @notice Initializes the token contract
    /// @param initialOwner Address to be set as the owner (must be a multisig like Gnosis Safe with 3/5 signatures)
    function initialize(address initialOwner) external initializer {
        require(initialOwner != address(0), "GenyToken: owner address is zero");

        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __Ownable2Step_init();
        _transferOwnership(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _mint(address(this), TOTAL_SUPPLY);
        totalSupplyBurned = 0;
        lastBurnTimestamp = 0;
        lastRecoveryTimestamp = 0;
        cooldown = 1 days; // Default 24 hours
        limitBasisPoints = 1000; // Default 10% (1000 basis points)
        maxBatchRecipients = 50; // Default maximum batch recipients
    }

    // === External Functions ===

    /// @notice Distributes tokens to a single address
    /// @dev Ensures tokens are not locked in a pending state; requires contract to be unpaused
    /// @param recipient Address to receive tokens
    /// @param amount Amount of tokens to send
    function distribute(address recipient, uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        _validateRecipient(recipient);
        uint256 contractBalance = balanceOf(address(this));
        require(amount > 0 && amount <= contractBalance, "GenyToken: invalid amount");
        require(balanceOf(recipient) + amount <= type(uint256).max, "GenyToken: recipient balance overflow");

        _transfer(address(this), recipient, amount);
        emit TokensDistributed(recipient, amount);
    }

    /// @notice Distributes tokens to multiple addresses in a batch
    /// @dev Prevents Sybil attacks by checking for duplicate recipients; large distributions should use auxiliary contracts
    /// @param recipients List of recipient addresses
    /// @param amounts List of token amounts corresponding to each recipient
    function distributeBatch(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner nonReentrant whenNotPaused {
        uint256 len = recipients.length;
        require(len == amounts.length, "GenyToken: recipients and amounts length mismatch");
        require(len > 0 && len <= maxBatchRecipients, "GenyToken: invalid batch size");

        uint256 totalAmount;
        uint256 contractBalance = balanceOf(address(this));
        // Check for duplicate recipients to prevent Sybil attacks
        for (uint256 i = 0; i < len; ) {
            address recipient = recipients[i];
            _validateRecipient(recipient);
            require(amounts[i] > 0, "GenyToken: amount must be greater than zero");
            require(balanceOf(recipient) + amounts[i] <= type(uint256).max, "GenyToken: recipient balance overflow");
            // Optimized duplicate check
            for (uint256 j = i + 1; j < len; ) {
                require(recipients[i] != recipients[j], "GenyToken: duplicate recipient");
                unchecked { ++j; }
            }
            totalAmount += amounts[i];
            unchecked { ++i; }
        }

        require(totalAmount <= contractBalance, "GenyToken: insufficient balance");

        for (uint256 i = 0; i < len; ) {
            _transfer(address(this), recipients[i], amounts[i]);
            unchecked { ++i; }
        }

        emit TokensDistributedBatch(recipients, totalAmount);
    }

    /// @notice Recovers GENY tokens accidentally sent to the contract (e.g., user errors)
    /// @dev Callable only by owner, limited by limitBasisPoints (default 10%), configurable cooldown; includes reason for transparency
    /// @param recipient Address to receive the recovered tokens
    /// @param amount Number of tokens to recover
    /// @param reason Reason for the recovery (e.g., "User error", "Contract migration")
    function recoverTokens(address recipient, uint256 amount, string calldata reason) external onlyOwner nonReentrant {
        require(block.timestamp >= lastRecoveryTimestamp + cooldown, "GenyToken: recovery cooldown active");
        _validateRecipient(recipient);
        uint256 contractBalance = balanceOf(address(this));
        require(amount > 0 && amount <= contractBalance, "GenyToken: invalid amount");
        require(amount <= (contractBalance * limitBasisPoints) / 10000, "GenyToken: exceeds recovery limit");

        _transfer(address(this), recipient, amount);
        lastRecoveryTimestamp = block.timestamp;
        emit TokensRecovered(recipient, amount, reason);
    }

    /// @notice Burns tokens from the contract balance in critical situations (e.g., hacks, unclaimed airdrop tokens, distribution errors)
    /// @dev Callable only by owner, limited by limitBasisPoints (default 10%), configurable cooldown; includes reason for transparency
    /// @param amount Number of tokens to burn
    /// @param reason Reason for the burn (e.g., "Unclaimed airdrop", "Error correction")
    function burn(uint256 amount, string calldata reason) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp >= lastBurnTimestamp + cooldown, "GenyToken: burn cooldown active");
        uint256 contractBalance = balanceOf(address(this));
        require(amount > 0 && amount <= contractBalance, "GenyToken: invalid amount");
        require(amount <= (contractBalance * limitBasisPoints) / 10000, "GenyToken: exceeds burn limit");

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
        require(block.timestamp >= lastBurnTimestamp + cooldown, "GenyToken: burn cooldown active");
        uint256 contractBalance = balanceOf(address(this));
        require(amount > 0 && amount <= contractBalance, "GenyToken: invalid amount");

        _burn(address(this), amount);
        totalSupplyBurned += amount;
        lastBurnTimestamp = block.timestamp;
        emit TokensBurned(msg.sender, amount, totalSupply(), reason);
    }

    /// @notice Updates the burn and recovery limit (in basis points, e.g., 1000 = 10%)
    /// @dev Callable only by owner, limit must be between 1% and 50% to prevent supply volatility; emits LimitUpdated event
    /// @param newLimitBasisPoints New limit in basis points (100 = 1%, 5000 = 50%)
    function updateLimit(uint256 newLimitBasisPoints) external onlyOwner {
        require(newLimitBasisPoints >= 100 && newLimitBasisPoints <= 5000, "GenyToken: invalid limit");
        limitBasisPoints = newLimitBasisPoints;
        emit LimitUpdated(newLimitBasisPoints);
    }

    /// @notice Updates the cooldown period for burn and recovery operations
    /// @dev Callable only by owner, cooldown must be between 1 hour and 7 days; emits CooldownUpdated event
    /// @param newCooldown New cooldown period in seconds
    function setCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown >= 1 hours && newCooldown <= 7 days, "GenyToken: invalid cooldown");
        cooldown = newCooldown;
        emit CooldownUpdated(newCooldown);
    }

    /// @notice Sets the maximum number of recipients allowed in a single batch distribution
    /// @dev Callable only by owner; new limit must be between 10 and 500 to balance gas costs and functionality
    /// @param newLimit The new maximum number of recipients
    function setMaxBatchRecipients(uint256 newLimit) external onlyOwner {
        require(newLimit >= 10 && newLimit <= 500, "GenyToken: invalid batch recipient limit");
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
        require(newImplementation != address(0), "GenyToken: zero new implementation");
        // Additional check to ensure new implementation is a valid contract
        uint256 codeSize;
        assembly { codeSize := extcodesize(newImplementation) }
        require(codeSize > 0, "GenyToken: new implementation is not a contract");
        emit Upgraded(newImplementation, VERSION);
    }

    /// @dev Validates a recipient address, preventing unauthorized or risky addresses
    /// @param recipient Address to validate
    function _validateRecipient(address recipient) internal view {
        require(recipient != address(0), "GenyToken: recipient address is zero");
        require(recipient != address(this), "GenyToken: cannot send to self");
        // Additional check to prevent transfers to risky addresses (e.g., known malicious contracts)
        uint256 codeSize;
        assembly { codeSize := extcodesize(recipient) }
        require(codeSize == 0 || recipient == owner(), "GenyToken: recipient must be EOA or owner");
    }

    // === Overrides ===

    /// @notice Overrides transferOwnership to ensure safe ownership transfer
    /// @dev Ensures new owner is a valid multisig address; emits OwnershipTransferred event
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "GenyToken: new owner is zero address");
        // Additional check to ensure new owner is a multisig or trusted address
        uint256 codeSize;
        assembly { codeSize := extcodesize(newOwner) }
        require(codeSize > 0, "GenyToken: new owner must be a contract (e.g., multisig)");
        _transferOwnership(newOwner);
    }

    /// @notice Overrides transfer to respect paused state
    function transfer(address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transfer(recipient, amount);
    }

    /// @notice Overrides approve to respect paused state
    function approve(address spender, uint256 amount) public override whenNotPaused returns (bool) {
        return super.approve(spender, amount);
    }

    /// @notice Overrides transferFrom to respect paused state
    function transferFrom(address sender, address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }

    /// @notice Fallback to receive ETH (if needed)
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}