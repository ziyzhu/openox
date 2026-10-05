# BytePlus ModelArk and Volcengine Ark

## Official destinations

- Global website: [BytePlus ModelArk](https://ai.byteplus.com/ark/home)
- Global developer documentation: [BytePlus ModelArk documentation](https://docs.byteplus.com/en/docs/ModelArk/1262002)
- China website: [Volcengine Ark](https://www.volcengine.com/product/ark)
- China developer documentation: [Volcengine Ark documentation](https://www.volcengine.com/docs/82379)
- Account management: BytePlus for Global or Volcengine for China. Current regional console deep links belong in the provider source.

## Ox account placement

Ox uses one provider identity with different display names and separate credentials for Global and China. Treat BytePlus and Volcengine as distinct account surfaces even though the provider composition is shared.

## Runtime sources

- Provider composition and regional mapping: [ModelArkProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/ModelArkProvider.swift)
- Curated models: [CuratedProviderModels.swift](../../../../apps/ios/Ox/Host/ModelProviders/CuratedProviderModels.swift)
