import { TestSummary } from "./testresultspublisher";
import * as tl from 'azure-pipelines-task-lib/task';
import tr = require('azure-pipelines-task-lib/toolrunner');
import { chmodSync, existsSync } from 'fs';
import * as path from "path";
import * as toolLib from 'vsts-task-tool-lib/tool';

export class TestRunner {
    constructor(testFilePath: string, imageName: string) {
        this.testFilePath = testFilePath;
        this.imageName = imageName;
    }

    public async Run(): Promise<TestSummary> {
        return new Promise<TestSummary>(async (resolve, reject) => {
            try {
                const runnerDownloadUrl = this.getContainerStructureTestRunnerDownloadPath(this.osType);
                if (!runnerDownloadUrl) {
                    throw new Error(`Not supported OS: ${this.osType}`);
                }

                let toolPath = toolLib.findLocalTool(this.toolName, "1.0.0");

                if(!toolPath) {
                    const downloadPath = await toolLib.downloadTool(runnerDownloadUrl);
                    tl.debug(`Successfully downloaded : ${downloadPath}`);
                    toolPath = await toolLib.cacheFile(downloadPath, this.toolName, this.toolName, "1.0.0");
                    tl.debug(`Successfully Added to cache`);
                } else {
                    tl.debug(`Tool is retrieved from cache.`);
                }

                var start = new Date().getTime();
                const output: string = this.runContainerStructureTest(path.join(toolPath, this.toolName), this.testFilePath, this.imageName);
                var end = new Date().getTime();

                if (!output || output.length <= 0) {
                    throw new Error("No output from runner");
                }
        
                tl.debug(`Successfully finished testing`);
                let resultObj: TestSummary = JSON.parse(output);
                resultObj.Duration = end-start;
                console.log(`Total Tests: ${resultObj.Total}, Pass: ${resultObj.Pass}, Fail: ${resultObj.Fail}`);
                resolve(resultObj);
            } catch (error) {
                reject(error)
            }
        });
    }

    private getContainerStructureTestRunnerDownloadPath(osType: string): string {
        switch (osType) {
            case 'darwin':
                return "https://storage.googleapis.com/container-structure-test/latest/container-structure-test-darwin-amd64";
            case 'linux':
                return "https://storage.googleapis.com/container-structure-test/latest/container-structure-test-linux-amd64";
            default:
                return null;
        }
    }

    private runContainerStructureTest(runnerPath: string, testFilePath: string, image: string): string {
        existsSync(runnerPath);
        chmodSync(runnerPath, "777");

        var toolPath = tl.which(runnerPath);

        if(!toolPath) {
            throw "Unable to find the Tool";
        }

        var tool:tr.ToolRunner = tl.tool(toolPath).arg(["test", "--image", image, "--config", testFilePath, "--json"]);
        let output = undefined;

        try {
            output = tool.execSync();
        } catch(error) {
            tl.error("Error While executing the tool: " + error);
            throw error;
        }

        let jsonOutput: string;

        if (output && !output.error) {
            jsonOutput = output.stdout;
        } else {
            tl.error(tl.loc('ErrorInExecutingCommand', output.error));
            throw new Error(tl.loc('ErrorInExecutingCommand', output.error));
        }
    
        tl.debug("Standard Output: " + output.stdout);
        tl.debug("Standard Error: " + output.stderr);
        tl.debug("Error from command executor: " + output.error);
        tl.debug("Return code from command executor: " + output.code);
    
        return jsonOutput;
    }

    private readonly testFilePath: string;
    private readonly imageName: string;
    private readonly osType = tl.osType().toLowerCase();
    private readonly toolName = "container-structure-test";
}