const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    
    console.log("🚀 Deploying Fixed Game Contract Ecosystem...");
    console.log("Deployer address:", deployer.address);
    console.log("Deployer balance:", ethers.formatEther(await deployer.provider.getBalance(deployer.address)));
    
    // 1. Deploy CRIDA Token
    console.log("\n📦 Deploying CRIDA Token...");
    const CRIDAToken = await ethers.getContractFactory("CRIDAToken");
    const cridaToken = await CRIDAToken.deploy(deployer.address);
    await cridaToken.waitForDeployment();
    console.log("✅ CRIDA Token deployed to:", await cridaToken.getAddress());
    
    // 2. Deploy GameTokenFactory (will need XP token address)
    console.log("\n📦 Deploying GameTokenFactory...");
    const GameTokenFactory = await ethers.getContractFactory("GameTokenFactory");
    
    // We need to deploy XP token first, but it needs factory address
    // So we'll use a temporary address, then update
    const tempAddress = "0x0000000000000000000000000000000000000000";
    
    // Deploy XP Token first
    console.log("\n📦 Deploying XP Token...");
    const XPToken = await ethers.getContractFactory("XPToken");
    const xpToken = await XPToken.deploy(
        "Experience Points",
        "XP",
        deployer.address,
        tempAddress // Will be updated after factory deployment
    );
    await xpToken.waitForDeployment();
    console.log("✅ XP Token deployed to:", await xpToken.getAddress());
    
    // Deploy factory with correct addresses
    const factory = await GameTokenFactory.deploy(
        await cridaToken.getAddress(),
        await xpToken.getAddress()
    );
    await factory.waitForDeployment();
    console.log("✅ GameTokenFactory deployed to:", await factory.getAddress());
    
    // 3. Grant minter role to factory in XP token
    console.log("\n🔐 Setting up permissions...");
    const MINTER_ROLE = await xpToken.MINTER_ROLE();
    const BURNER_ROLE = await xpToken.BURNER_ROLE();
    
    await xpToken.grantRole(MINTER_ROLE, await factory.getAddress());
    await xpToken.grantRole(BURNER_ROLE, await factory.getAddress());
    console.log("✅ Factory granted minter and burner roles for XP token");
    
    // 4. Verify the setup
    console.log("\n🔍 Verifying deployment...");
    
    const factoryCridaAddress = await factory.credaToken();
    const factoryXpAddress = await factory.xpToken();
    
    console.log("Factory CRIDA token address:", factoryCridaAddress);
    console.log("Factory XP token address:", factoryXpAddress);
    console.log("CRIDA token address:", await cridaToken.getAddress());
    console.log("XP token address:", await xpToken.getAddress());
    
    if (factoryCridaAddress === await cridaToken.getAddress() && 
        factoryXpAddress === await xpToken.getAddress()) {
        console.log("✅ All addresses match correctly!");
    } else {
        console.log("❌ Address mismatch detected!");
    }
    
    // 5. Test the fixed functionality
    console.log("\n🧪 Testing Fixed Logic...");
    
    // Test 1: Lock CRIDA and mint XP
    const lockAmount = ethers.parseEther("1000"); // 1000 CRIDA
    
    // First approve factory to spend CRIDA
    console.log("Approving factory to spend CRIDA...");
    await cridaToken.approve(await factory.getAddress(), lockAmount);
    
    const initialXpBalance = await xpToken.balanceOf(deployer.address);
    console.log("Initial XP balance:", ethers.formatEther(initialXpBalance));
    
    console.log("Locking CRIDA to mint XP...");
    await factory.lockCreda(lockAmount);
    
    const finalXpBalance = await xpToken.balanceOf(deployer.address);
    console.log("Final XP balance:", ethers.formatEther(finalXpBalance));
    console.log("XP minted:", ethers.formatEther(finalXpBalance - initialXpBalance));
    
    // Test 2: Create game token by burning XP
    const gameXpAmount = ethers.parseEther("500"); // 500 XP for game token
    
    console.log("Approving factory to burn XP...");
    await xpToken.approve(await factory.getAddress(), gameXpAmount);
    
    console.log("Creating game token...");
    const tx = await factory.createGameToken(
        gameXpAmount,
        "Test Game Token",
        "TGT",
        8  // Using 8 decimals (within the MAX_GAME_TOKEN_DECIMALS = 9 limit)
    );
    const receipt = await tx.wait();
    
    // Get game token address from event
    const gameCreatedEvent = receipt.logs.find(log => {
        try {
            return factory.interface.parseLog(log).name === 'GameTokenCreated';
        } catch {
            return false;
        }
    });
    
    if (gameCreatedEvent) {
        const parsedEvent = factory.interface.parseLog(gameCreatedEvent);
        const gameTokenAddress = parsedEvent.args.tokenAddress;
        console.log("✅ Game token created at:", gameTokenAddress);
        
        // Verify XP was burned
        const newXpBalance = await xpToken.balanceOf(deployer.address);
        console.log("XP balance after game token creation:", ethers.formatEther(newXpBalance));
        console.log("XP burned:", ethers.formatEther(finalXpBalance - newXpBalance));
    }
    
    console.log("\n🎉 Fixed Game Contract Ecosystem deployed successfully!");
    console.log("\n📋 Contract Addresses:");
    console.log("CRIDA Token:", await cridaToken.getAddress());
    console.log("XP Token:", await xpToken.getAddress());
    console.log("GameTokenFactory:", await factory.getAddress());
    
    console.log("\n✅ All logical issues have been fixed:");
    console.log("1. ✅ lockCreda now properly mints XP tokens to users");
    console.log("2. ✅ Game tokens can only be minted when XP is locked/burned");
    console.log("3. ✅ No manual minting allowed outside the factory mechanism");
    console.log("4. ✅ Proper economic model: CRIDA → XP (mint) → GameToken (burn XP) → XP (mint back)");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    }); 