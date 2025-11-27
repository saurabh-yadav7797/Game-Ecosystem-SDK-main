const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

  // Deploy mock tokens for testing (in production, use real CREDA and XP tokens)
  console.log("\n=== Deploying Mock Tokens ===");
  
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  
  const credaToken = await MockERC20.deploy(
    "CREDA Token",
    "CREDA", 
    18,
    ethers.parseEther("1000000") // 1M tokens
  );
  await credaToken.waitForDeployment();
  console.log("CREDA Token deployed to:", await credaToken.getAddress());

  const xpToken = await MockERC20.deploy(
    "XP Token",
    "XP",
    18,
    ethers.parseEther("1000000") // 1M tokens
  );
  await xpToken.waitForDeployment();
  console.log("XP Token deployed to:", await xpToken.getAddress());

  // Deploy GameTokenFactory (Enhanced Security Version)
  console.log("\n=== Deploying Enhanced GameTokenFactory ===");
  
  const GameTokenFactory = await ethers.getContractFactory("GameTokenFactory");
  const gameTokenFactory = await GameTokenFactory.deploy(
    await credaToken.getAddress(),
    await xpToken.getAddress()
  );
  await gameTokenFactory.waitForDeployment();
  console.log("GameTokenFactory deployed to:", await gameTokenFactory.getAddress());

  // Setup initial configuration
  console.log("\n=== Initial Setup ===");
  
  // Transfer some XP tokens to the GameTokenFactory contract for locking operations
  const xpForContract = ethers.parseEther("500000"); // 500K XP tokens
  await xpToken.transfer(await gameTokenFactory.getAddress(), xpForContract);
  console.log("Transferred", ethers.formatEther(xpForContract), "XP tokens to GameTokenFactory");

  // Setup roles (optional - for demonstration)
  console.log("\n=== Setting Up Roles (Optional) ===");
  const RATE_MANAGER_ROLE = await gameTokenFactory.RATE_MANAGER_ROLE();
  const PAUSER_ROLE = await gameTokenFactory.PAUSER_ROLE();
  const EMERGENCY_ROLE = await gameTokenFactory.EMERGENCY_ROLE();
  
  console.log("RATE_MANAGER_ROLE:", RATE_MANAGER_ROLE);
  console.log("PAUSER_ROLE:", PAUSER_ROLE);
  console.log("EMERGENCY_ROLE:", EMERGENCY_ROLE);

  // Verify the setup
  console.log("\n=== Verification ===");
  console.log("CREDA to XP rate:", ethers.formatEther(await gameTokenFactory.credaToXpRate()));
  console.log("Next game ID:", await gameTokenFactory.nextGameId());
  console.log("XP reserves:", ethers.formatEther(await gameTokenFactory.xpReserves()));
  console.log("Min XP lock amount:", ethers.formatEther(await gameTokenFactory.MIN_XP_LOCK_AMOUNT()));
  console.log("Max game token decimals:", await gameTokenFactory.MAX_GAME_TOKEN_DECIMALS());

  // Demonstrate the flow with enhanced security
  console.log("\n=== Demonstrating Enhanced Security Flow ===");
  
  try {
    // 1. Lock CREDA to get XP
    const credaLockAmount = ethers.parseEther("1000");
    console.log("1. Approving and locking", ethers.formatEther(credaLockAmount), "CREDA tokens...");
    
    await credaToken.approve(await gameTokenFactory.getAddress(), credaLockAmount);
    await gameTokenFactory.lockCreda(credaLockAmount);
    
    const xpBalance = await xpToken.balanceOf(deployer.address);
    console.log("   XP received:", ethers.formatEther(xpBalance));

    // 2. Create game token (separate ERC-20 deployment)
    const xpLockAmount = ethers.parseEther("2000");
    console.log("2. Creating game token with", ethers.formatEther(xpLockAmount), "XP...");
    
    await xpToken.approve(await gameTokenFactory.getAddress(), xpLockAmount);
    const tx = await gameTokenFactory.createGameToken(
      xpLockAmount,
      "Demo Racing Game",
      "RACE",
      18
    );
    const receipt = await tx.wait();
    
    // Find the GameTokenCreated event
    const event = receipt.logs.find(log => {
      try {
        return gameTokenFactory.interface.parseLog(log).name === "GameTokenCreated";
      } catch {
        return false;
      }
    });
    
    if (event) {
      const parsedEvent = gameTokenFactory.interface.parseLog(event);
      const gameId = parsedEvent.args[0];
      const tokenAddress = parsedEvent.args[2];
      
      console.log("   Game ID:", gameId.toString());
      console.log("   Game Token Address:", tokenAddress);
      console.log("   Gas used:", receipt.gasUsed.toString());
      
      // 3. Verify the deployed game token
      const GameToken = await ethers.getContractFactory("GameToken");
      const gameToken = GameToken.attach(tokenAddress);
      
      const tokenName = await gameToken.name();
      const tokenSymbol = await gameToken.symbol();
      const tokenBalance = await gameToken.balanceOf(deployer.address);
      
      console.log("3. Deployed Game Token Details:");
      console.log("   Name:", tokenName);
      console.log("   Symbol:", tokenSymbol);
      console.log("   Balance:", ethers.formatEther(tokenBalance));
      
      // 4. Demonstrate burning
      const burnAmount = ethers.parseEther("1000");
      console.log("4. Burning", ethers.formatEther(burnAmount), "game tokens...");
      
      await gameTokenFactory.burnGameToken(gameId, burnAmount);
      
      const finalXpBalance = await xpToken.balanceOf(deployer.address);
      const finalGameTokenBalance = await gameToken.balanceOf(deployer.address);
      
      console.log("   XP balance after burn:", ethers.formatEther(finalXpBalance));
      console.log("   Game token balance after burn:", ethers.formatEther(finalGameTokenBalance));
    }
    
  } catch (error) {
    console.log("Demo flow error (expected in some environments):", error.message);
  }

  console.log("\n=== Deployment Summary ===");
  console.log({
    "CREDA Token": await credaToken.getAddress(),
    "XP Token": await xpToken.getAddress(),
    "GameTokenFactory": await gameTokenFactory.getAddress(),
    "Deployer": deployer.address
  });

  // Save deployment addresses to a file
  const fs = require('fs');
  const deploymentData = {
    network: await ethers.provider.getNetwork(),
    timestamp: new Date().toISOString(),
    contracts: {
      credaToken: await credaToken.getAddress(),
      xpToken: await xpToken.getAddress(),
      gameTokenFactory: await gameTokenFactory.getAddress()
    },
    deployer: deployer.address,
    features: {
      maintainsOriginalFlow: true,
      enhancedSecurity: true,
      gasOptimized: true,
      separateERC20Deployment: true
    }
  };

  fs.writeFileSync(
    `deployment-${deploymentData.network.chainId}.json`,
    JSON.stringify(deploymentData, null, 2)
  );
  console.log(`\nDeployment data saved to deployment-${deploymentData.network.chainId}.json`);
  
  console.log("\n🎯 Enhanced Security Features Deployed:");
  console.log("✅ Reentrancy protection on all external functions");
  console.log("✅ Role-based access control with granular permissions");
  console.log("✅ Emergency pause functionality");
  console.log("✅ Comprehensive input validation");
  console.log("✅ Gas-optimized packed structs");
  console.log("✅ Separate ERC-20 game token deployments (original flow maintained)");
  console.log("✅ Duplicate name prevention per user");
  console.log("✅ Emergency token recovery");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 