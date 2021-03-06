async function main() {
	const [deployer] = await ethers.getSigners();
	console.log(`Deployer address: ${deployer.address}`);
	const deployerBalance = await deployer.getBalance();
	console.log(`Deployer balance: ${deployerBalance}`);

	const provider = deployer.provider;
	const network = await provider.getNetwork();
	console.log(`Network: ${network.name} is ${network.name === "kovan"}`);

	const networkGasPrice = (await provider.getGasPrice()).toNumber();
	const gasPrice = parseInt(networkGasPrice * 1.05);
	console.log(`Gas Price balance: ${gasPrice}`);

	// get the contract to deploy
	const AnchorFlashLiquidator = await ethers.getContractFactory("AnchorFlashLiquidator");
	const anchorFlashLiq = await AnchorFlashLiquidator.deploy({ gasPrice });
	await anchorFlashLiq.deployed();
	console.log(`AnchorFlashLiquidator address: ${anchorFlashLiq.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(1);
	});
