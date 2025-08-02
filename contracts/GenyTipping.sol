// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap
pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title GenyTipping
/// @author compez.eth
/// @notice Manages tipping campaigns for GENY tokens with labeled multipliers
/// @dev Supports tipping with labels (e.g., Supporter, Champion) and multipliers, integrated with GenyAirdrop for quotas.
/// Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
/// @custom:security-contact security@genyleap.com
contract GenyTipping is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice The GENY token contract
    IERC20Upgradeable public token;
    /// @notice Address of the GenyAirdrop contract
    address public airdropContract;
    /// @notice Minimum GENY holding required for tipping
    uint96 public minHolding;

    /// @dev Structure to store label details
    struct Label {
        uint32 multiplier; // Multiplier for tipping quota
        bool active; // Label status
    }

    /// @dev Structure to store recipient details
    struct Recipient {
        string labelName; // Assigned label
        uint96 dailyQuota; // Daily tipping quota
        uint96 usedQuota; // Used quota
        uint48 lastQuotaReset; // Last reset timestamp
        bool isActive; // Recipient status
    }

    /// @dev Structure to store tip details
    struct Tip {
        address sender; // Address of the tip sender
        address recipient; // Address of the tip recipient
        uint96 amount; // Amount of tokens tipped
        uint32 seasonId; // Season ID for the tip
        uint48 timestamp; // Timestamp of the tip
        string labelName; // Label associated with the tip
    }

    /// @notice Mapping of label names to their details
    mapping(string => Label) public labels;
    /// @notice Mapping of user addresses to their recipient details
    mapping(address => Recipient) public recipients;
    /// @notice Array of all tips
    Tip[] public tips;

    /// @notice Emitted when a tip is submitted
    event TipSubmitted(address indexed sender, address indexed recipient, uint32 indexed seasonId, uint96 amount, string label);
    /// @notice Emitted when a recipient's label is updated
    event RecipientLabelUpdated(address indexed user, string labelName);
    /// @notice Emitted when the minimum holding is updated
    event MinHoldingUpdated(uint96 newMinHolding);
    /// @notice Emitted when a label is updated
    event LabelUpdated(string indexed name, uint32 multiplier, bool active);
    /// @notice Emitted when a recipient's status is updated
    event RecipientStatusUpdated(address indexed user, bool isActive);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the tipping contract
    /// @param _token Address of the GENY token contract
    /// @param _airdropContract Address of the GenyAirdrop contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    function initialize(
        address _token,
        address _airdropContract,
        address _owner
    ) external initializer {
        require(_token != address(0) && _airdropContract != address(0) && _owner != address(0), "Invalid address");
        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        token = IERC20Upgradeable(_token);
        airdropContract = _airdropContract;
        minHolding = 500 * 1e18; // 500 GENY
        // Initialize labels
        labels["Supporter"] = Label(2, true);
        labels["Contributor"] = Label(8, true);
        labels["Influencer"] = Label(16, true);
        labels["Champion"] = Label(32, true);
        labels["Trailblazer"] = Label(64, true);
        labels["Icon"] = Label(128, true);
        labels["Legend"] = Label(256, true);
    }

    /// @notice Updates the minimum holding for tipping
    /// @param _newMinHolding New minimum holding amount
    function updateMinHolding(uint96 _newMinHolding) external onlyOwner {
        require(_newMinHolding > 0, "Invalid min holding");
        minHolding = _newMinHolding;
        emit MinHoldingUpdated(_newMinHolding);
    }

    /// @notice Updates a label's multiplier and status
    /// @param _name Label name
    /// @param _multiplier New multiplier
    /// @param _active New status
    function updateLabel(string memory _name, uint32 _multiplier, bool _active) external onlyOwner {
        require(bytes(_name).length > 0 && _multiplier > 0, "Invalid label data");
        labels[_name] = Label(_multiplier, _active);
        emit LabelUpdated(_name, _multiplier, _active);
    }

    /// @notice Updates a recipient's label and status
    /// @param _user Recipient address
    /// @param _labelName New label name
    /// @param _isActive New status
    function updateRecipient(address _user, string memory _labelName, bool _isActive) external onlyOwner {
        require(_user != address(0) && bytes(_labelName).length > 0, "Invalid data");
        require(labels[_labelName].active, "Label not active");
        recipients[_user] = Recipient({
            labelName: _labelName,
            dailyQuota: 0,
            usedQuota: 0,
            lastQuotaReset: 0,
            isActive: _isActive
        });
        emit RecipientLabelUpdated(_user, _labelName);
        emit RecipientStatusUpdated(_user, _isActive);
    }

    /// @notice Submits a tip to a recipient
    /// @dev Consumes the sender's tipping quota from the GenyAirdrop contract
    /// @param _recipient Address of the tip recipient
    /// @param _amount Amount of tokens to tip
    /// @param _seasonId Season ID for the tip
    /// @param _maxTippingAmount Maximum allowed tipping amount
    /// @param _merkleProof Merkle proof for eligibility
    function submitTip(
        address _recipient,
        uint96 _amount,
        uint32 _seasonId,
        uint256 _maxTippingAmount,
        bytes32[] calldata _merkleProof
    ) external nonReentrant whenNotPaused {
        require(_recipient != address(0) && _amount > 0, "Invalid tip data");
        require(token.balanceOf(msg.sender) >= minHolding, "Insufficient holding");
        require(recipients[msg.sender].isActive, "User not eligible");
        _updateQuota(msg.sender, _seasonId);
        Recipient storage recipient = recipients[msg.sender];
        require(recipient.usedQuota + _amount <= recipient.dailyQuota, "Exceeds daily quota");
        IGenyAirdrop airdrop = IGenyAirdrop(airdropContract);
        uint32 multiplier = labels[recipient.labelName].multiplier;
        require(airdrop.getTippingQuota(msg.sender, _seasonId, multiplier) >= _amount, "Insufficient tipping quota");
        require(!airdrop.isSeasonEnded(_seasonId), "Season ended");
        // Use sender's quota instead of recipient's
        airdrop.useTippingQuota(msg.sender, _seasonId, _amount, multiplier, _maxTippingAmount, _merkleProof);
        recipient.usedQuota += _amount;
        tips.push(Tip({
            sender: msg.sender,
            recipient: _recipient,
            amount: _amount,
            seasonId: _seasonId,
            timestamp: uint48(block.timestamp),
            labelName: recipient.labelName
        }));
        emit TipSubmitted(msg.sender, _recipient, _seasonId, _amount, recipient.labelName);
    }

    /// @dev Updates a user's tipping quota
    /// @param _user Address of the user
    /// @param _seasonId Season ID
    function _updateQuota(address _user, uint32 _seasonId) private {
        Recipient storage recipient = recipients[_user];
        uint48 currentDay = uint48(block.timestamp / 1 days);
        if (currentDay > uint48(recipient.lastQuotaReset / 1 days) || recipient.dailyQuota == 0) {
            IGenyAirdrop airdrop = IGenyAirdrop(airdropContract);
            uint32 multiplier = labels[recipient.labelName].active ? labels[recipient.labelName].multiplier : 1;
            recipient.dailyQuota = uint96(airdrop.getTippingQuota(_user, _seasonId, multiplier));
            recipient.usedQuota = 0;
            recipient.lastQuotaReset = uint48(block.timestamp);
        }
    }

    /// @notice Returns user quota details
    /// @param _user Address of the user
    /// @return labelName Label name
    /// @return dailyQuota Daily tipping quota
    /// @return usedQuota Used quota
    /// @return lastQuotaReset Last reset timestamp
    /// @return isActive Recipient status
    function getUserQuotaDetails(address _user) external view returns (
        string memory labelName,
        uint96 dailyQuota,
        uint96 usedQuota,
        uint48 lastQuotaReset,
        bool isActive
    ) {
        Recipient storage recipient = recipients[_user];
        return (
            recipient.labelName,
            recipient.dailyQuota,
            recipient.usedQuota,
            recipient.lastQuotaReset,
            recipient.isActive
        );
    }

    /// @notice Returns the total number of tips
    /// @return count Number of tips
    function getTipCount() external view returns (uint256 count) {
        count = tips.length;
    }

    /// @notice Returns details of a specific tip
    /// @param _index Tip index
    /// @return sender Sender address
    /// @return recipient Recipient address
    /// @return amount Tip amount
    /// @return seasonId Season ID
    /// @return timestamp Tip timestamp
    /// @return labelName Label name
    function getTip(uint256 _index) external view returns (
        address sender,
        address recipient,
        uint96 amount,
        uint32 seasonId,
        uint48 timestamp,
        string memory labelName
    ) {
        require(_index < tips.length, "Invalid tip index");
        Tip storage tip = tips[_index];
        return (
            tip.sender,
            tip.recipient,
            tip.amount,
            tip.seasonId,
            tip.timestamp,
            tip.labelName
        );
    }

    /// @notice Pauses the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

interface IGenyAirdrop {
    function getTippingQuota(address user, uint32 seasonId, uint32 multiplier) external view returns (uint256);
    function useTippingQuota(address user, uint32 seasonId, uint96 amount, uint32 multiplier, uint256 maxTippingAmount, bytes32[] calldata merkleProof) external;
    function isSeasonEnded(uint32 seasonId) external view returns (bool);
}