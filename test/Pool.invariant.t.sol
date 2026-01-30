// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../src/Pool.sol";
import "../src/PoolFactory.sol";
import "../src/ShareToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20Inv is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Handler contract for invariant testing
contract PoolHandler is Test {
    Pool public pool;
    MockERC20Inv public usdc;
    address public admin;
    
    address[] public actors;
    address[] public depositors;
    
    uint256 public ghost_depositSum;
    uint256 public ghost_withdrawSum;
    
    mapping(address => uint256) public ghost_userDeposits;
    mapping(address => uint256) public ghost_userWithdrawals;
    
    constructor(Pool _pool, MockERC20Inv _usdc, address _admin) {
        pool = _pool;
        usdc = _usdc;
        admin = _admin;
        
        // Create actors
        for (uint256 i = 0; i < 10; i++) {
            address actor = address(uint160(100 + i));
            actors.push(actor);
            
            // Whitelist and fund
            vm.prank(admin);
            pool.addToWhitelist(actor);
            usdc.mint(actor, 10_000 * 1e18);
        }
    }
    
    function deposit(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % actors.length];
        (,, uint256 minDep,,,,) = pool.config();
        amount = bound(amount, minDep, usdc.balanceOf(actor));
        
        if (amount < minDep) return;
        
        vm.startPrank(actor);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
        
        ghost_depositSum += amount;
        ghost_userDeposits[actor] += amount;
        
        // Track depositors
        bool isDepositor = false;
        for (uint256 i = 0; i < depositors.length; i++) {
            if (depositors[i] == actor) {
                isDepositor = true;
                break;
            }
        }
        if (!isDepositor) depositors.push(actor);
    }
    
    function withdraw(uint256 actorSeed, uint256 amount) public {
        if (depositors.length == 0) return;
        
        address actor = depositors[actorSeed % depositors.length];
        uint256 shares = pool.shareToken().balanceOf(actor);
        
        if (shares == 0) return;
        
        amount = bound(amount, 1, shares);
        
        vm.prank(actor);
        pool.withdraw(amount);
        
        ghost_withdrawSum += amount;
        ghost_userWithdrawals[actor] += amount;
    }
    
    function getDepositors() external view returns (address[] memory) {
        return depositors;
    }
    
    function getActors() external view returns (address[] memory) {
        return actors;
    }
}

contract PoolInvariantTest is StdInvariant, Test {
    PoolFactory factory;
    Pool pool;
    MockERC20Inv usdc;
    PoolHandler handler;
    
    address admin = address(1);
    address guardian1 = address(5);
    address guardian2 = address(6);
    
    function setUp() public {
        usdc = new MockERC20Inv();
        factory = new PoolFactory();
        
        vm.startPrank(admin);
        
        address[] memory guardians = new address[](2);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        
        address poolAddr = factory.createPool(
            "Invariant Test Pool",
            address(usdc),
            100 * 1e18,
            3 days,
            5000,
            6000,
            2000,
            guardians
        );
        
        pool = Pool(payable(poolAddr));
        vm.stopPrank();
        
        handler = new PoolHandler(pool, usdc, admin);
        
        // Target only the handler
        targetContract(address(handler));
    }
    
    // ============ Invariant 1: Share Supply == Total Deposited ============
    // Only valid when no requests have been funded
    
    function invariant_ShareSupplyMatchesDeposits() public view {
        // Since we're not funding requests in this handler, this should hold
        assertEq(
            pool.shareToken().totalSupply(),
            pool.totalDeposited(),
            "Share supply must equal total deposited"
        );
    }
    
    // ============ Invariant 2: Pool Balance >= Total Deposited ============
    
    function invariant_PoolSolvency() public view {
        uint256 poolBalance = usdc.balanceOf(address(pool));
        
        assertGe(
            poolBalance,
            pool.totalDeposited(),
            "Pool must be solvent"
        );
    }
    
    // ============ Invariant 3: User Shares == Deposits - Withdrawals ============
    
    function invariant_UserSharesMatchNetDeposits() public view {
        address[] memory depositors = handler.getDepositors();
        
        for (uint256 i = 0; i < depositors.length; i++) {
            address user = depositors[i];
            uint256 userShares = pool.shareToken().balanceOf(user);
            uint256 userDeposits = handler.ghost_userDeposits(user);
            uint256 userWithdrawals = handler.ghost_userWithdrawals(user);
            uint256 expectedShares = userDeposits - userWithdrawals;
            
            assertEq(
                userShares,
                expectedShares,
                "User shares must equal net deposits"
            );
        }
    }
    
    // ============ Invariant 4: Total Shares == Sum of Individual Shares ============
    
    function invariant_TotalSharesConsistent() public view {
        address[] memory depositors = handler.getDepositors();
        uint256 sumOfShares = 0;
        
        for (uint256 i = 0; i < depositors.length; i++) {
            sumOfShares += pool.shareToken().balanceOf(depositors[i]);
        }
        
        assertEq(
            sumOfShares,
            pool.shareToken().totalSupply(),
            "Sum of shares must equal total supply"
        );
    }
    
    // ============ Invariant 5: Ghost Deposits - Withdrawals == Total Deposited ============
    
    function invariant_GhostAccountingAccurate() public view {
        uint256 netDeposits = handler.ghost_depositSum() - handler.ghost_withdrawSum();
        
        assertEq(
            netDeposits,
            pool.totalDeposited(),
            "Ghost accounting must match totalDeposited"
        );
    }
    
    // ============ Invariant 6: Members With Shares Are Active ============
    
    function invariant_ShareholdersMustBeActive() public view {
        address[] memory depositors = handler.getDepositors();
        
        for (uint256 i = 0; i < depositors.length; i++) {
            address user = depositors[i];
            uint256 shares = pool.shareToken().balanceOf(user);
            (bool isActive,,) = pool.members(user);
            
            // If has shares, must be active
            if (shares > 0) {
                assertTrue(isActive, "Member with shares must be active");
            }
        }
    }
    
    // ============ Invariant 7: No Shares For Non-Members ============
    
    function invariant_OnlyMembersHaveShares() public view {
        address[] memory actors = handler.getActors();
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 shares = pool.shareToken().balanceOf(actor);
            (bool isActive,,) = pool.members(actor);
            
            // If not active, must have 0 shares
            if (!isActive) {
                assertEq(shares, 0, "Non-member must have 0 shares");
            }
        }
    }
}
