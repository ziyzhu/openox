# Amazon Bedrock

## Official destinations

- Website: [Amazon Bedrock](https://aws.amazon.com/bedrock/)
- Developer documentation: [Amazon Bedrock User Guide](https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html)
- API-key guidance: [Amazon Bedrock API keys](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-reference.html)
- Account management: AWS Console for Amazon Bedrock. The current Ox deep link belongs in the provider source.

## Ox account placement

Ox presents Bedrock in Global and deliberately routes through Amazon Bedrock in US East (N. Virginia). Do not infer broader Ox routing from AWS's wider service availability. Bedrock API keys are region-bound, so a key created elsewhere may not work with the Ox integration.

## Runtime sources

- Provider composition and selected AWS region: [AmazonBedrockProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/AmazonBedrockProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

Bedrock is one provider that composes OpenAI Responses and Anthropic Messages transports. Keep that routing in code.
