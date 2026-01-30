// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ShareToken.sol";

/**
 * @title Pool
 * @notice A Peer Credit Circle pool where friends pool funds and vote on funding requests
 * @dev Main contract handling deposits, withdrawals, funding requests, voting, and rewards
 */
contract Pool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum RequestType {
        GRANT,      // No repayment expected, no collateral required
        LOAN,       // Repay principal + interest, collateral required
        INVESTMENT  // Token/equity return, collateral required
    }

    enum RequestStatus {
        PENDING,    // Just created, waiting for voting to start
        VOTING,     // Active voting period
        APPROVED,   // Vote passed, awaiting execution/guardian sign
        REJECTED,   // Vote failed
        FUNDED,     // Funds released to requester
        COMPLETED,  // Requester completed obligations
        DEFAULTED,  // Requester failed to deliver
        CANCELLED   // Cancelled by requester before voting ends
    }

    // ============ Structs ============

    struct PoolConfig {
        string name;
        address depositToken;       // ETH = address(0), or ERC20 address
        uint256 minDeposit;
        uint256 votingPeriod;       // Duration in seconds
        uint256 quorumBps;          // Minimum participation (5000 = 50%)
        uint256 approvalThresholdBps; // YES votes needed (6000 = 60%)
        uint256 guardianThresholdBps; // Amount triggering guardian sign (2000 = 20%)
    }

    struct FundingRequest {
        uint256 id;
        address requester;
        string title;
        string descriptionUri;      // IPFS link
        uint256 amount;
        RequestType requestType;
        uint256 rewardBps;          // Expected return (1000 = 10%)
        uint256 duration;           // Time to complete/repay
        uint256 collateralAmount;   // Required for LOAN/INVESTMENT
        address collateralToken;    // Token used for collateral
        RequestStatus status;
        uint256 votingEndsAt;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 fundedAt;
        uint256 repaidAmount;
    }

    struct Member {
        bool isActive;
        bool isGuardian;
        uint256 joinedAt;
    }

    // ============ State Variables ============

    PoolConfig public config;
    ShareToken public shareToken;
    address public admin;
    bool public isOpen;
    uint256 public totalDeposited;
    uint256 public totalPendingFunding; // Amount locked for approved requests

    // Members
    mapping(address => Member) public members;
    address[] public memberList;
    address[] public guardianList;

    // Whitelist for invite-only
    mapping(address => bool) public whitelist;

    // Funding Requests
    uint256 public nextRequestId;
    mapping(uint256 => FundingRequest) public requests;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public guardianApprovals;
    mapping(uint256 => uint256) public guardianApprovalCount;

    // Rewards tracking (per token)
    mapping(address => uint256) public cumulativeRewardPerShare;
    mapping(address => mapping(address => uint256)) public memberRewardDebt;

    // ============ Events ============

    event Deposited(address indexed member, uint256 amount, uint256 shares);
    event Withdrawn(address indexed member, uint256 amount, uint256 shares);
    event MemberWhitelisted(address indexed member);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event RequestCreated(uint256 indexed requestId, address indexed requester, uint256 amount, RequestType requestType);
    event VoteCast(uint256 indexed requestId, address indexed voter, bool support, uint256 weight);
    event RequestApproved(uint256 indexed requestId);
    event RequestRejected(uint256 indexed requestId);
    event RequestFunded(uint256 indexed requestId, address indexed requester, uint256 amount);
    event RequestCompleted(uint256 indexed requestId);
    event RequestDefaulted(uint256 indexed requestId);
    event GuardianApproval(uint256 indexed requestId, address indexed guardian);
    event RewardsDistributed(address indexed token, uint256 amount);
    event RewardsClaimed(address indexed member, address indexed token, uint256 amount);
    event CollateralDeposited(uint256 indexed requestId, address indexed token, uint256 amount);
    event CollateralReturned(uint256 indexed requestId, address indexed requester, uint256 amount);
    event CollateralSlashed(uint256 indexed requestId, uint256 amount);

    // ============ Errors ============

    error NotAdmin();
    error NotMember();
    error NotGuardian();
    error NotWhitelisted();
    error AlreadyMember();
    error PoolNotOpen();
    error BelowMinDeposit();
    error InsufficientShares();
    error InsufficientPoolFunds();
    error InvalidRequestType();
    error CollateralRequired();
    error RequestNotFound();
    error InvalidStatus();
    error VotingNotStarted();
    error VotingEnded();
    error VotingNotEnded();
    error AlreadyVoted();
    error NotRequester();
    error RequestTooLarge();
    error GuardianApprovalRequired();
    error AlreadyApproved();
    error ZeroAmount();
    error InvalidAddress();

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyMember() {
        if (!members[msg.sender].isActive) revert NotMember();
        _;
    }

    modifier onlyGuardian() {
        if (!members[msg.sender].isGuardian) revert NotGuardian();
        _;
    }

    // ============ Constructor ============

    constructor(
        PoolConfig memory _config,
        address _admin,
        address[] memory _initialGuardians
    ) {
        config = _config;
        admin = _admin;
        isOpen = true;

        // Deploy share token
        string memory tokenSymbol = string(abi.encodePacked("PCC-", _config.name));
        shareToken = new ShareToken(_config.name, tokenSymbol);

        // Set up initial guardians
        for (uint256 i = 0; i < _initialGuardians.length; i++) {
            address guardian = _initialGuardians[i];
            whitelist[guardian] = true;
            members[guardian] = Member({ isActive: false, isGuardian: true, joinedAt: 0 });
            guardianList.push(guardian);
            emit GuardianAdded(guardian);
        }

        // Admin is always whitelisted
        whitelist[_admin] = true;
    }

    // ============ Admin Functions ============

    /**
     * @notice Whitelist an address to join the pool (invite-only)
     * @param _member Address to whitelist
     */
    function addToWhitelist(address _member) external onlyAdmin {
        if (_member == address(0)) revert InvalidAddress();
        whitelist[_member] = true;
        emit MemberWhitelisted(_member);
    }

    /**
     * @notice Batch whitelist addresses
     * @param _members Addresses to whitelist
     */
    function batchWhitelist(address[] calldata _members) external onlyAdmin {
        for (uint256 i = 0; i < _members.length; i++) {
            if (_members[i] != address(0)) {
                whitelist[_members[i]] = true;
                emit MemberWhitelisted(_members[i]);
            }
        }
    }

    /**
     * @notice Add a guardian
     * @param _guardian Address to make guardian
     */
    function addGuardian(address _guardian) external onlyAdmin {
        if (_guardian == address(0)) revert InvalidAddress();
        if (!members[_guardian].isActive) revert NotMember();
        members[_guardian].isGuardian = true;
        guardianList.push(_guardian);
        emit GuardianAdded(_guardian);
    }

    /**
     * @notice Remove a guardian
     * @param _guardian Address to remove as guardian
     */
    function removeGuardian(address _guardian) external onlyAdmin {
        members[_guardian].isGuardian = false;
        // Note: doesn't remove from guardianList array for gas efficiency
        emit GuardianRemoved(_guardian);
    }

    /**
     * @notice Toggle pool open/closed for new deposits
     */
    function toggleOpen() external onlyAdmin {
        isOpen = !isOpen;
    }

    // ============ Member Functions ============

    /**
     * @notice Deposit funds into the pool
     * @dev For ETH pools, send ETH with the call. For ERC20, approve first.
     * @param amount Amount to deposit (ignored for ETH, uses msg.value)
     */
    function deposit(uint256 amount) external payable nonReentrant {
        if (!isOpen) revert PoolNotOpen();
        if (!whitelist[msg.sender]) revert NotWhitelisted();

        uint256 depositAmount;

        if (config.depositToken == address(0)) {
            // ETH deposit
            depositAmount = msg.value;
        } else {
            // ERC20 deposit
            depositAmount = amount;
            IERC20(config.depositToken).safeTransferFrom(msg.sender, address(this), depositAmount);
        }

        if (depositAmount < config.minDeposit) revert BelowMinDeposit();

        // Calculate shares (1:1 for first deposit, proportional after)
        uint256 shares;
        uint256 totalShares = shareToken.totalSupply();

        if (totalShares == 0) {
            shares = depositAmount;
        } else {
            shares = (depositAmount * totalShares) / totalDeposited;
        }

        // Update state
        totalDeposited += depositAmount;

        // Add as member if not already
        if (!members[msg.sender].isActive) {
            members[msg.sender] = Member({ isActive: true, isGuardian: members[msg.sender].isGuardian, joinedAt: block.timestamp });
            memberList.push(msg.sender);
        }

        // Mint shares
        shareToken.mint(msg.sender, shares);

        emit Deposited(msg.sender, depositAmount, shares);
    }

    /**
     * @notice Withdraw funds from the pool
     * @param shares Amount of shares to redeem
     */
    function withdraw(uint256 shares) external nonReentrant onlyMember {
        if (shares == 0) revert ZeroAmount();
        if (shareToken.balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 totalShares = shareToken.totalSupply();
        uint256 availableFunds = totalDeposited - totalPendingFunding;
        uint256 amount = (shares * availableFunds) / totalShares;

        if (amount > availableFunds) revert InsufficientPoolFunds();

        // Burn shares first (CEI pattern)
        shareToken.burn(msg.sender, shares);
        totalDeposited -= amount;

        // Transfer funds
        if (config.depositToken == address(0)) {
            (bool success,) = msg.sender.call{ value: amount }("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(config.depositToken).safeTransfer(msg.sender, amount);
        }

        emit Withdrawn(msg.sender, amount, shares);
    }

    // ============ Funding Request Functions ============

    /**
     * @notice Create a funding request
     * @param title Short title
     * @param descriptionUri IPFS link to full description
     * @param amount Amount requested
     * @param requestType GRANT, LOAN, or INVESTMENT
     * @param rewardBps Expected return in basis points
     * @param duration Time to complete in seconds
     * @param collateralToken Token for collateral (if required)
     * @param collateralAmount Amount of collateral
     */
    function createRequest(
        string calldata title,
        string calldata descriptionUri,
        uint256 amount,
        RequestType requestType,
        uint256 rewardBps,
        uint256 duration,
        address collateralToken,
        uint256 collateralAmount
    ) external nonReentrant returns (uint256) {
        if (amount == 0) revert ZeroAmount();
        
        // Check pool has enough funds
        uint256 availableFunds = totalDeposited - totalPendingFunding;
        if (amount > availableFunds) revert InsufficientPoolFunds();

        // Max single request = 30% of pool
        if (amount > (totalDeposited * 3000) / 10000) revert RequestTooLarge();

        // Collateral required for LOAN and INVESTMENT
        if (requestType != RequestType.GRANT) {
            if (collateralAmount == 0) revert CollateralRequired();
            // Transfer collateral
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        }

        uint256 requestId = nextRequestId++;

        requests[requestId] = FundingRequest({
            id: requestId,
            requester: msg.sender,
            title: title,
            descriptionUri: descriptionUri,
            amount: amount,
            requestType: requestType,
            rewardBps: rewardBps,
            duration: duration,
            collateralAmount: collateralAmount,
            collateralToken: collateralToken,
            status: RequestStatus.VOTING,
            votingEndsAt: block.timestamp + config.votingPeriod,
            yesVotes: 0,
            noVotes: 0,
            fundedAt: 0,
            repaidAmount: 0
        });

        if (collateralAmount > 0) {
            emit CollateralDeposited(requestId, collateralToken, collateralAmount);
        }

        emit RequestCreated(requestId, msg.sender, amount, requestType);

        return requestId;
    }

    /**
     * @notice Vote on a funding request
     * @param requestId ID of the request
     * @param support True for YES, false for NO
     */
    function vote(uint256 requestId, bool support) external onlyMember {
        FundingRequest storage request = requests[requestId];

        if (request.status != RequestStatus.VOTING) revert InvalidStatus();
        if (block.timestamp >= request.votingEndsAt) revert VotingEnded();
        if (hasVoted[requestId][msg.sender]) revert AlreadyVoted();

        uint256 weight = shareToken.balanceOf(msg.sender);

        if (support) {
            request.yesVotes += weight;
        } else {
            request.noVotes += weight;
        }

        hasVoted[requestId][msg.sender] = true;

        emit VoteCast(requestId, msg.sender, support, weight);
    }

    /**
     * @notice Finalize voting and determine outcome
     * @param requestId ID of the request
     */
    function finalizeVoting(uint256 requestId) external {
        FundingRequest storage request = requests[requestId];

        if (request.status != RequestStatus.VOTING) revert InvalidStatus();
        if (block.timestamp < request.votingEndsAt) revert VotingNotEnded();

        uint256 totalVotes = request.yesVotes + request.noVotes;
        uint256 totalShares = shareToken.totalSupply();

        // Check quorum
        bool quorumMet = (totalVotes * 10000) / totalShares >= config.quorumBps;

        // Check approval threshold
        bool approved = quorumMet && (request.yesVotes * 10000) / totalVotes >= config.approvalThresholdBps;

        if (approved) {
            request.status = RequestStatus.APPROVED;
            totalPendingFunding += request.amount;
            emit RequestApproved(requestId);
        } else {
            request.status = RequestStatus.REJECTED;
            // Return collateral if rejected
            if (request.collateralAmount > 0) {
                IERC20(request.collateralToken).safeTransfer(request.requester, request.collateralAmount);
                emit CollateralReturned(requestId, request.requester, request.collateralAmount);
            }
            emit RequestRejected(requestId);
        }
    }

    /**
     * @notice Guardian approval for large requests
     * @param requestId ID of the request
     */
    function guardianApprove(uint256 requestId) external onlyGuardian {
        FundingRequest storage request = requests[requestId];

        if (request.status != RequestStatus.APPROVED) revert InvalidStatus();
        if (guardianApprovals[requestId][msg.sender]) revert AlreadyApproved();

        guardianApprovals[requestId][msg.sender] = true;
        guardianApprovalCount[requestId]++;

        emit GuardianApproval(requestId, msg.sender);
    }

    /**
     * @notice Execute an approved funding request
     * @param requestId ID of the request
     */
    function executeRequest(uint256 requestId) external nonReentrant {
        FundingRequest storage request = requests[requestId];

        if (request.status != RequestStatus.APPROVED) revert InvalidStatus();

        // Check if guardian approval needed (>= 20% of pool)
        bool needsGuardian = request.amount >= (totalDeposited * config.guardianThresholdBps) / 10000;

        if (needsGuardian) {
            // Need majority of guardians
            uint256 activeGuardians = _countActiveGuardians();
            uint256 required = (activeGuardians / 2) + 1;
            if (guardianApprovalCount[requestId] < required) revert GuardianApprovalRequired();
        }

        // Update state
        request.status = RequestStatus.FUNDED;
        request.fundedAt = block.timestamp;
        totalPendingFunding -= request.amount;
        totalDeposited -= request.amount;

        // Transfer funds
        if (config.depositToken == address(0)) {
            (bool success,) = request.requester.call{ value: request.amount }("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(config.depositToken).safeTransfer(request.requester, request.amount);
        }

        emit RequestFunded(requestId, request.requester, request.amount);
    }

    /**
     * @notice Mark a request as completed and return collateral
     * @param requestId ID of the request
     */
    function completeRequest(uint256 requestId) external onlyGuardian {
        FundingRequest storage request = requests[requestId];

        if (request.status != RequestStatus.FUNDED) revert InvalidStatus();

        request.status = RequestStatus.COMPLETED;

        // Return collateral
        if (request.collateralAmount > 0) {
            IERC20(request.collateralToken).safeTransfer(request.requester, request.collateralAmount);
            emit CollateralReturned(requestId, request.requester, request.collateralAmount);
        }

        emit RequestCompleted(requestId);
    }

    /**
     * @notice Mark a request as defaulted and slash collateral
     * @param requestId ID of the request
     */
    function markDefaulted(uint256 requestId) external {
        FundingRequest storage request = requests[requestId];

        if (request.status != RequestStatus.FUNDED) revert InvalidStatus();
        
        // Can only default after duration has passed
        if (block.timestamp < request.fundedAt + request.duration) revert InvalidStatus();

        request.status = RequestStatus.DEFAULTED;

        // Slash collateral - distribute to pool
        if (request.collateralAmount > 0) {
            // For simplicity, collateral goes back to pool treasury
            // In future, could convert to deposit token and add to totalDeposited
            emit CollateralSlashed(requestId, request.collateralAmount);
        }

        emit RequestDefaulted(requestId);
    }

    /**
     * @notice Cancel a request (only by requester, only during voting)
     * @param requestId ID of the request
     */
    function cancelRequest(uint256 requestId) external {
        FundingRequest storage request = requests[requestId];

        if (msg.sender != request.requester) revert NotRequester();
        if (request.status != RequestStatus.VOTING) revert InvalidStatus();

        request.status = RequestStatus.CANCELLED;

        // Return collateral
        if (request.collateralAmount > 0) {
            IERC20(request.collateralToken).safeTransfer(request.requester, request.collateralAmount);
            emit CollateralReturned(requestId, request.requester, request.collateralAmount);
        }
    }

    // ============ Rewards Functions ============

    /**
     * @notice Distribute rewards to pool members
     * @param token Token to distribute
     * @param amount Amount to distribute
     */
    function distributeRewards(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 totalShares = shareToken.totalSupply();
        if (totalShares > 0) {
            cumulativeRewardPerShare[token] += (amount * 1e18) / totalShares;
        }

        emit RewardsDistributed(token, amount);
    }

    /**
     * @notice Claim pending rewards
     * @param token Token to claim
     */
    function claimRewards(address token) external nonReentrant onlyMember {
        uint256 shares = shareToken.balanceOf(msg.sender);
        uint256 accumulated = (shares * cumulativeRewardPerShare[token]) / 1e18;
        uint256 owed = accumulated - memberRewardDebt[msg.sender][token];

        if (owed > 0) {
            memberRewardDebt[msg.sender][token] = accumulated;
            IERC20(token).safeTransfer(msg.sender, owed);
            emit RewardsClaimed(msg.sender, token, owed);
        }
    }

    /**
     * @notice Get pending rewards for a member
     * @param member Address to check
     * @param token Token to check
     */
    function pendingRewards(address member, address token) external view returns (uint256) {
        uint256 shares = shareToken.balanceOf(member);
        uint256 accumulated = (shares * cumulativeRewardPerShare[token]) / 1e18;
        return accumulated - memberRewardDebt[member][token];
    }

    // ============ View Functions ============

    function getMemberCount() external view returns (uint256) {
        return memberList.length;
    }

    function getGuardianCount() external view returns (uint256) {
        return _countActiveGuardians();
    }

    function getRequest(uint256 requestId) external view returns (FundingRequest memory) {
        return requests[requestId];
    }

    function getAvailableFunds() external view returns (uint256) {
        return totalDeposited - totalPendingFunding;
    }

    function getMemberShare(address member) external view returns (uint256 shares, uint256 percentage) {
        shares = shareToken.balanceOf(member);
        uint256 total = shareToken.totalSupply();
        percentage = total > 0 ? (shares * 10000) / total : 0;
    }

    // ============ Internal Functions ============

    function _countActiveGuardians() internal view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < guardianList.length; i++) {
            if (members[guardianList[i]].isGuardian) {
                count++;
            }
        }
        return count;
    }

    // Allow receiving ETH
    receive() external payable {}
}
