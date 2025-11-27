const hre = require("hardhat");

async function main() {
  console.log("Deploying contracts for testing game token creation...");
  
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Deploy mock CRIDA token for testing
  const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
  const credaToken = await MockERC20.deploy(
    "CRIDA Token", 
    "CRIDA", 
    18, // decimals
    hre.ethers.parseEther("1000000") // Initial supply
  );
  await credaToken.waitForDeployment();
  console.log("Mock CRIDA Token deployed to:", await credaToken.getAddress());

  // Deploy XPToken
  const XPToken = await hre.ethers.getContractFactory("XPToken");
  const xpToken = await XPToken.deploy("XP Token", "XPT", deployer.address, deployer.address);
  await xpToken.waitForDeployment();
  console.log("XPToken deployed to:", await xpToken.getAddress());

  // Deploy GameTokenFactory with correct parameters
  const GameTokenFactory = await hre.ethers.getContractFactory("GameTokenFactory");
  const gameTokenFactory = await GameTokenFactory.deploy(
    await credaToken.getAddress(),  // _credaToken
    await xpToken.getAddress()      // _xpToken
  );
  await gameTokenFactory.waitForDeployment();
  console.log("GameTokenFactory deployed to:", await gameTokenFactory.getAddress());

  // Grant roles to GameTokenFactory
  const minterRole = await xpToken.MINTER_ROLE();
  const burnerRole = await xpToken.BURNER_ROLE();
  await xpToken.grantRole(minterRole, await gameTokenFactory.getAddress());
  await xpToken.grantRole(burnerRole, await gameTokenFactory.getAddress());
  console.log("Roles granted to GameTokenFactory");

  // Mint XP tokens for testing
  const xpAmount = hre.ethers.parseEther("10");
  await xpToken.mint(deployer.address, xpAmount);
  console.log(`Minted ${xpAmount} XP tokens to ${deployer.address}`);

  // Approve XP tokens for GameTokenFactory
  await xpToken.approve(await gameTokenFactory.getAddress(), xpAmount);
  console.log(`Approved ${xpAmount} XP tokens for GameTokenFactory`);

  // Create a game token
  console.log("Creating game token...");
  try {
    const tx = await gameTokenFactory.createGameToken(
      hre.ethers.parseEther("10"), // XP amount
      "Test Game", // name
      "TGT",      // symbol
      6           // decimals
    );
    const receipt = await tx.wait();
    console.log("Game token created successfully!");
    
    // Find GameTokenCreated event
    const gameCreatedEvent = receipt.logs
      .filter(log => {
        try {
          const parsedLog = gameTokenFactory.interface.parseLog({
            topics: log.topics,
            data: log.data
          });
          return parsedLog && parsedLog.name === "GameTokenCreated";
        } catch (e) {
          return false;
        }
      })
      .map(log => {
        return gameTokenFactory.interface.parseLog({
          topics: log.topics,
          data: log.data
        });
      })[0];
    
    if (gameCreatedEvent) {
      const { gameId, creator, tokenAddress, name, symbol, xpAmount, initialSupply } = gameCreatedEvent.args;
      console.log("Game Token Details:");
      console.log("- Game ID:", gameId.toString());
      console.log("- Creator:", creator);
      console.log("- Token Address:", tokenAddress);
      console.log("- Name:", name);
      console.log("- Symbol:", symbol);
      console.log("- XP Locked:", hre.ethers.formatEther(xpAmount));
      console.log("- Initial Supply:", initialSupply.toString());
    }
  } catch (error) {
    console.error("Error creating game token:", error);
    
    // Try to extract revert reason if possible
    if (error.data) {
      const revertReason = `0x${error.data.slice(10)}`;
      console.log("Revert data:", revertReason);
      
      try {
        const decodedError = gameTokenFactory.interface.parseError(revertReason);
        console.log("Decoded error:", decodedError);
      } catch (e) {
        console.log("Could not decode error data");
      }
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}); 