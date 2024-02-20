import ballerina/http;
import ballerinax/googleapis.gmail;

import wso2/ai.agent;

// openai key
configurable string openAiToken = ?;

// train API auth configs
configurable string clientId = ?;
configurable string clientSecret = ?;
configurable string tokenUrl = ?;

// gmail API auth configs
configurable string gmailRefreshToken = ?;
configurable string gmailClientId = ?;
configurable string gmailClientSecret = ?;

const string TRAIN_API_SPEC_PATH = "openapi/train-service.json";
const string EMAIL_ADDRESS = "demo.train.info@gmail.com";

type UserInput record {|
    string command;
    string userEmail;
    string userLocation;
|};

// Useful to send mails to a given email address
isolated function sendMail(record {|string senderEmail; gmail:MessageRequest messageRequest;|} input) returns string|error {
    gmail:Client gmail = check new ({
        auth: {
            refreshToken: gmailRefreshToken,
            clientId: gmailClientId,
            clientSecret: gmailClientSecret
        }
    });
    gmail:Message message = check gmail->/users/[input.senderEmail]/messages/send.post(input.messageRequest);
    return message.toString();
}

isolated service / on new http:Listener(9090) {
    final agent:FunctionCallAgent agent;
    function init() returns error? {
        // 1) create tool for sending emails
        agent:Tool gmailTool = {
            name: "sendMail",
            description: "Send an email to a given email address with booking details. Email body is given in HTML using `bodyInHtml`.",
            caller: sendMail,
            parameters: {
                properties: {
                    senderEmail: {
                        'const: EMAIL_ADDRESS
                    },
                    messageRequest: {
                        properties: {
                            to: {
                                items: {
                                    'type: agent:STRING
                                }
                            },
                            subject: {
                                'type: agent:STRING
                            },
                            bodyInHtml: {
                                'type: agent:STRING,
                                format: "text/html"
                            }
                        }
                    }
                }
            }
        };

        // 2) load tools from open api spec file for the train API
        agent:HttpApiSpecification apiSpecification = check agent:extractToolsFromOpenApiSpecFile(TRAIN_API_SPEC_PATH);
        string? serviceUrl = apiSpecification.serviceUrl;
        if (serviceUrl == null) {
            return error("Service URL not found for the openapi file");
        }
        agent:HttpServiceToolKit trainApi = check new (serviceUrl, apiSpecification.tools, {
            auth: {
                tokenUrl,
                clientId,
                clientSecret
            }
        });

        // 3) create the model
        agent:ChatGptModel model = check new ({auth: {token: openAiToken}});
        // 4) initialize the agent
        self.agent = check new (model, gmailTool, trainApi);
    }

    resource function post execute(@http:Payload UserInput payload) returns json|error {
        // 5) execute the user command
        record {|(agent:ExecutionResult|agent:ExecutionError)[] steps; string answer?;|} executionResults =
        agent:run(self.agent, query = payload.command, context = {
            "My Location": payload.userLocation,
            "My Email": payload.userEmail,
            "Current Time": "19.00" // hard coded for clarity, instead can use system time
        }, maxIter = 10);

        // returns only the final outcome
        string? answer = executionResults.answer;
        if answer == null {
            return error("Failed to execute the given command.");
        }
        return {"answer": answer};
    }
}

