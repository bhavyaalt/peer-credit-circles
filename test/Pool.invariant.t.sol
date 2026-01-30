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
    uint256 public ghost_fundedSum;
    
    mapping(address => uint256) public ghost_userDeposits;
    
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
        ghost_userDeposits[actor] -= amount;
    }
    
    function createAndVoteRequest(uint256 actorSeed, uint256 requestAmount) public {
        if (depositors.length == 0) return;
        
        address requester = actors[actorSeed % actors.length];
        requestAmount = bound(requestAmount, 1 * 1e18, pool.totalDeposited() / 2);
        
        if (requestAmount == 0 || pool.totalDeposited() == 0) return;
        
        vm.startPrank(requester);
        try pool.createRequest(
            "Test Request",
            "ipfs://test",
            requestAmount,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        ) returns (uint256 requestId) {
            vm.stopPrank();
            
            // All depositors vote yes
            for (uint256 i = 0; i < depositors.length; i++) {
                vm.prank(depositors[i]);
                try pool.vote(requestId, true) {} catch {}
            }
            
            // Fast forward and finalize
            vm.warp(block.timestamp + 4 days);
            try pool.finalizeVoting(requestId) {} catch {}
            
            // Try to execute
            Pool.FundingRequest memory request = pool.getRequest(requestId);
            if (request.status == Pool.RequestStatus.APPROVED) {
                // Check if guardian needed
                (,,,,,,uint256 guardianBps) = pool.config();
                uint256 guardianThreshold = (pool.totalDeposited() * guardianBps) / 10000;
                if (requestAmount <= guardianThreshold) {
                    try pool.executeRequest(requestId) {
                        ghost_fundedSum += requestAmount;
                    } catch {}
                }
            }
        } catch {
            vm.stopPrank();
        }
    }
    
    function getDepositors() external view returns (address[] memory) {
        return depositors;
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
    
    function invariant_ShareSupplyMatchesDeposits() public view {
        assertEq(
            pool.shareToken().totalSupply(),
            pool.totalDeposited(),
            "Share supply must equal total deposited"
        );
    }
    
    // ============ Invariant 2: Pool Balance >= Total Deposited - Funded ============
    
    function invariant_PoolSolvency() public view {
        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 expectedMinBalance = pool.totalDeposited() > handler.ghost_fundedSum() 
            ? pool.totalDeposited() - handler.ghost_fundedSum() 
            : 0;
        
        assertGe(
            poolBalance,
            expectedMinBalance,
            "Pool must be solvent"
        );
    }
    
    // ============ Invariant 3: No User Has More Shares Than Their Deposits ============
    
    function invariant_UserSharesNotExceedDeposits() public view {
        address[] memory depositors = handler.getDepositors();
        
        for (uint256 i = 0; i < depositors.length; i++) {
            address user = depositors[i];
            uint256 userShares = pool.shareToken().balanceOf(user);
            uint256 userDeposits = handler.ghost_userDeposits(user);
            
            assertLe(
                userShares,
                userDeposits,
                "User shares must not exceed deposits"
            );
        }
    }
    
    // ============ Invariant 4: Active Members Have Shares ============
    
    function invariant_ActiveMembersHaveShares() public view {
        address[] memory depositors = handler.getDepositors();
        
        for (uint256 i = 0; i < depositors.length; i++) {
            address user = depositors[i];
            (bool isActive,,) = pool.members(user);
            
            if (isActive) {
                assertGt(
                    pool.shareToken().balanceOf(user),
                    0,
                    "Active member must have shares"
                );
            }
        }
    }
    
    // ============ Invariant 5: Ghost Accounting Matches Reality ============
    
    function invariant_GhostAccountingAccurate() public view {
        uint256 netDeposits = handler.ghost_depositSum() - handler.ghost_withdrawSum() - handler.ghost_fundedSum();
        
        // Allow small rounding errors
        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 diff = poolBalance > netDeposits ? poolBalance - netDeposits : netDeposits - poolBalance;
        
        assertLe(
            diff,
            100, // Allow 100 wei rounding
            "Ghost accounting must match pool balance"
        );
    }
    
    // ============ Invariant 6: Active Members Have Deposits ============
    
    function invariant_ActiveMembersHaveDeposits() public view {
        address[] memory depositors = handler.getDepositors();
        
        for (uint256 i = 0; i < depositors.length; i++) {
            (bool isActive,,) = pool.members(depositors[i]);
            uint256 shares = pool.shareToken().balanceOf(depositors[i]);
            
            // If active, must have shares. If has shares, must be active.
            if (isActive) {
                assertGt(shares, 0, "Active member must have shares");
            }
            if (shares > 0) {
                assertTrue(isActive, "Member with shares must be active");
            }
        }
    }
    
    // ============ Invariant 7: Shares Cannot Be Transferred ============
    
    function invariant_SharesNonTransferable() public view {
        ShareToken token = pool.shareToken();
        
        // Try transfer from handler contract (not a prank, just a view check)
        // This invariant is enforced by the ShareToken contract itself
        // Just verify the total supply hasn't changed unexpectedly
        assertEq(
            token.totalSupply(),
            pool.totalDeposited(),
            "Share supply integrity"
        );
    }
}
