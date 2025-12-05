const { ethers } = require("hardhat");

/**
 * Diamond Launchpad Deployment Script
 * 
 * Deploys all facets, the Diamond proxy, and configures:
 * - Function selectors for all facets
 * - DEX addresses (Uniswap V3)
 * - Wrapper implementation
 * - Fee configuration
 */

// MegaETH Testnet Uniswap V3 addresses
const UNISWAP_V3_FACTORY = "0x94996d371622304f2eb85df1eb7f328f7b317c3e";
const POSITION_MANAGER = "0x1279f3cbf01ad4f0cfa93f233464581f4051033a";
const WETH = "0x4200000000000000000000000000000000000006";

// ERC-20 wrapper implementation (deploy separately or use existing)
const WRAPPER_IMPLEMENTATION = "0x06aA00B602E7679cD25782aCe884Fb92f8F48b36";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Diamond Launchpad Deployment");
    console.log("============================");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // Step 1: Deploy all facets
    console.log("Step 1: Deploying Facets...\n");
    const facets = await deployFacets();

    // Step 2: Deploy DiamondInit
    console.log("\nStep 2: Deploying DiamondInit...");
    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();
    console.log("DiamondInit:", await diamondInit.getAddress());

    // Step 3: Deploy Diamond proxy
    console.log("\nStep 3: Deploying Diamond...");
    const Diamond = await ethers.getContractFactory("Diamond");
    const diamond = await Diamond.deploy(deployer.address, await facets.diamondCut.getAddress());
    await diamond.waitForDeployment();
    const diamondAddress = await diamond.getAddress();
    console.log("Diamond:", diamondAddress);

    // Step 4: Prepare and execute diamond cut
    console.log("\nStep 4: Adding Facets to Diamond...");
    const cut = prepareDiamondCut(facets);
    const initParams = {
        platformWallet: deployer.address,
        buybackWallet: deployer.address,
        defaultCreatorFee: 5000,
        defaultPlatformFee: 2500,
        defaultBuybackFee: 2500,
        uniswapV3Factory: UNISWAP_V3_FACTORY,
        nonfungiblePositionManager: POSITION_MANAGER,
        weth: WETH,
        wrapperFactory: diamondAddress
    };
    const initCalldata = diamondInit.interface.encodeFunctionData("init", [initParams]);
    
    const diamondCutContract = await ethers.getContractAt("IDiamondCut", diamondAddress);
    const cutTx = await diamondCutContract.diamondCut(cut, await diamondInit.getAddress(), initCalldata, { gasLimit: 5000000 });
    await cutTx.wait();
    console.log("Diamond cut executed!");

    // Step 5: Post-deployment configuration
    console.log("\nStep 5: Configuring Diamond...");
    
    const wrapperFacet = await ethers.getContractAt(
        ["function setWrapperImplementation(address) external"],
        diamondAddress
    );
    await (await wrapperFacet.setWrapperImplementation(WRAPPER_IMPLEMENTATION)).wait();
    console.log("Wrapper implementation set");

    const graduationFacet = await ethers.getContractAt(
        ["function setDEXAddresses(address,address,address) external"],
        diamondAddress
    );
    await (await graduationFacet.setDEXAddresses(UNISWAP_V3_FACTORY, POSITION_MANAGER, WETH)).wait();
    console.log("DEX addresses set");

    // Step 6: Verify deployment
    console.log("\nStep 6: Verifying Deployment...");
    await verifyDeployment(diamondAddress, facets);

    // Output summary
    console.log("\n============================");
    console.log("Deployment Complete!");
    console.log("============================");
    console.log("Diamond:", diamondAddress);
    console.log("\nFacets:");
    for (const [name, facet] of Object.entries(facets)) {
        console.log(`  ${name}: ${await facet.getAddress()}`);
    }

    // Save deployment
    const fs = require("fs");
    const deployment = {
        network: hre.network.name,
        diamond: diamondAddress,
        facets: {},
        diamondInit: await diamondInit.getAddress(),
        config: { UNISWAP_V3_FACTORY, POSITION_MANAGER, WETH, WRAPPER_IMPLEMENTATION }
    };
    for (const [name, facet] of Object.entries(facets)) {
        deployment.facets[name] = await facet.getAddress();
    }
    fs.mkdirSync("./deployments", { recursive: true });
    fs.writeFileSync(`./deployments/${hre.network.name}-${Date.now()}.json`, JSON.stringify(deployment, null, 2));

    return deployment;
}

/**
 * Deploy all facet contracts
 */
async function deployFacets() {
    const facets = {};
    const facetNames = [
        "DiamondCutFacet",
        "DiamondLoupeFacet", 
        "TokenFacet",
        "TradingFacet",
        "GraduationFacet",
        "FeeFacet",
        "SecurityFacet",
        "AdminFacet",
        "ERC6909Facet",
        "WrapperFacet"
    ];

    for (const name of facetNames) {
        const Factory = await ethers.getContractFactory(name);
        const facet = await Factory.deploy();
        await facet.waitForDeployment();
        const key = name.replace("Facet", "").charAt(0).toLowerCase() + name.replace("Facet", "").slice(1);
        facets[key] = facet;
        console.log(`${name}: ${await facet.getAddress()}`);
    }

    return facets;
}

/**
 * Prepare diamond cut with all facet selectors
 */
function prepareDiamondCut(facets) {
    const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };
    const registeredSelectors = new Set();
    const cut = [];

    const facetOrder = [
        "diamondLoupe",
        "token", 
        "trading",
        "graduation",
        "fee",
        "security",
        "admin",
        "erc6909",
        "wrapper"
    ];

    for (const name of facetOrder) {
        const facet = facets[name];
        if (!facet) continue;

        const selectors = [];
        facet.interface.forEachFunction((func) => {
            if (func.name === "init") return;
            if (!registeredSelectors.has(func.selector)) {
                selectors.push(func.selector);
                registeredSelectors.add(func.selector);
            }
        });

        if (selectors.length > 0) {
            cut.push({
                facetAddress: facet.target,
                action: FacetCutAction.Add,
                functionSelectors: selectors
            });
        }
    }

    console.log(`Prepared ${registeredSelectors.size} selectors across ${cut.length} facets`);
    return cut;
}

/**
 * Verify key functions are registered
 */
async function verifyDeployment(diamondAddress, facets) {
    const loupe = await ethers.getContractAt("IDiamondLoupe", diamondAddress);
    const registeredFacets = await loupe.facets();
    
    let totalSelectors = 0;
    for (const facet of registeredFacets) {
        totalSelectors += facet.functionSelectors.length;
    }
    console.log(`Total selectors: ${totalSelectors}`);

    // New 18-param createToken signature
    const keyFunctions = [
        "createToken(string,string,string,string,string,string,string,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256)",
        "initializeToken(address)",
        "buyWithETH(address,address,uint256)",
        "sellToken(address,uint256,address,uint256)",
        "setSellsEnabled(address,bool)",
        "graduate(address)",
        "collectFees(address)",
        "claimCreatorRewards()",
        "owner()"
    ];

    for (const sig of keyFunctions) {
        const selector = ethers.id(sig).slice(0, 10);
        const facetAddr = await loupe.facetAddress(selector);
        const found = facetAddr !== ethers.ZeroAddress;
        console.log(`${found ? "✓" : "✗"} ${sig.split("(")[0]}`);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
