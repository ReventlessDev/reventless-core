import {spawn} from 'child_process';

const didSucceed = (code) => `${code}` === '0';

function gitInit(_, config) {
	const spawnOptions = config.verbose ? {
		cwd: config.path,
		shell: true,
		stdio: 'inherit',
	} : {
		cwd: config.path
	};

	const gitInitLocal = () =>
		new Promise((resolve, reject) => {
			const gitInit = spawn('git', ['init', '--initial-branch=dev'], spawnOptions);

			gitInit.on('close', (code) => {
				if (didSucceed(code)) {
					resolve(`git init ran correctly`);
				} else {
					reject(`git init exited with ${code}`);
				}
			});
		});

	const gitAdd = () =>
		new Promise((resolve, reject) => {
			const gitAdd = spawn('git', ['add', '-A'], spawnOptions);

			gitAdd.on('close', (code) => {
				if (didSucceed(code)) {
					resolve(`git add ran correctly`);
				} else {
					reject(`git add exited with ${code}`);
				}
			});
		});

	const gitCommit = () =>
		new Promise((resolve, reject) => {
			const gitAdd = spawn('git', ['commit', '-m "Initial commit"'], spawnOptions);

			gitAdd.on('close', (code) => {
				if (didSucceed(code)) {
					resolve(`git commit ran correctly`);
				} else {
					reject(`git add exited with ${code}`);
				}
			});
		});

	return gitInitLocal()
		.then(() => gitAdd())
		.then(() => gitCommit());
}

function npmInstall(_, config) {
	const spawnOptions = config.verbose ? {
		cwd: config.path,
		shell: true,
		stdio: 'inherit',
	} : {
		cwd: config.path
	};

	return new Promise((resolve, reject) => {
		const npmI = spawn('npm', ['install'], spawnOptions);

		npmI.on('close', (code) => {
			if (didSucceed(code)) {
				resolve(`npm install ran correctly`);
			} else {
				reject(`npm install exited with ${code}`);
			}
		});
	});
}

function rebuild(_, config) {
	const spawnOptions = config.verbose ? {
		cwd: config.path,
		shell: true,
		stdio: 'inherit',
	} : {
		cwd: config.path
	};

	return new Promise((resolve, reject) => {
		const npmI = spawn('npm', ['run', 'rebuild'], spawnOptions);

		npmI.on('close', (code) => {
			if (didSucceed(code)) {
				resolve(`rebuild ran correctly`);
			} else {
				reject(`rebuild exited with ${code}`);
			}
		});
	});
}

export default function (plop) {
	plop.setDefaultInclude({actionTypes: true});
	plop.setActionType('gitInit', gitInit);
	plop.setActionType('npmInstall', npmInstall);
	plop.setActionType('rebuild', rebuild);
}
