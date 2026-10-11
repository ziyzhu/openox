window.ox.install(({ action }) => {
  let cachedCatalog = null;
  let cacheTime = 0;
  const CACHE_TTL = 10 * 60 * 1000;
  const MAX_SERIALIZED_BYTES = 256 * 1024;

  function guardSize(obj) {
    const json = JSON.stringify(obj);
    const byteLength = new TextEncoder().encode(json).length;
    if (byteLength > MAX_SERIALIZED_BYTES) {
      throw new Error('Response payload exceeds 256 KiB serialized size limit');
    }
    return obj;
  }

  async function getCatalog() {
    const now = Date.now();
    if (cachedCatalog && (now - cacheTime < CACHE_TTL)) {
      return cachedCatalog;
    }
    const resp = await fetch('https://models.dev/api.json');
    if (!resp.ok) {
      throw new Error('Failed to fetch models.dev catalog: HTTP ' + resp.status);
    }
    cachedCatalog = await resp.json();
    cacheTime = now;
    return cachedCatalog;
  }

  action('listProviders', {
    async invoke(args) {
      const catalog = await getCatalog();
      const providerIds = Object.keys(catalog).sort();
      const limit = Math.min(Math.max(Number(args.limit ?? 50), 1), 200);
      let startIndex = 0;
      if (args.cursor) {
        const idx = providerIds.indexOf(args.cursor);
        if (idx === -1) {
          throw new Error('Invalid or expired cursor');
        }
        startIndex = idx;
      }
      const sliceIds = providerIds.slice(startIndex, startIndex + limit);
      const items = sliceIds.map(id => {
        const p = catalog[id];
        const models = p.models || {};
        const env = Array.isArray(p.env) ? p.env : (p.env ? [p.env] : []);
        return {
          id: p.id || id,
          name: p.name || id,
          api: p.api ?? null,
          doc: p.doc ?? null,
          npm: p.npm ?? null,
          env,
          modelCount: Object.keys(models).length
        };
      });
      const nextIndex = startIndex + limit;
      const nextCursor = nextIndex < providerIds.length ? providerIds[nextIndex] : null;
      return guardSize({ items, nextCursor });
    }
  });

  action('searchModels', {
    async invoke(args) {
      const catalog = await getCatalog();
      const query = String(args.query || '').toLowerCase().trim();
      const filterProvider = args.provider ? String(args.provider).toLowerCase().trim() : null;
      const limit = Math.min(Math.max(Number(args.limit ?? 20), 1), 100);

      const allModels = [];
      const providerIds = Object.keys(catalog).sort();

      for (const pId of providerIds) {
        const p = catalog[pId];
        const canonicalProviderId = (p.id || pId).toLowerCase();
        if (filterProvider && canonicalProviderId !== filterProvider) {
          continue;
        }
        const models = p.models || {};
        for (const mKey of Object.keys(models).sort()) {
          const m = models[mKey];
          const mId = m.id || mKey;
          const mName = m.name || mKey;
          const mFamily = m.family || null;
          const mDesc = m.description || null;

          if (query) {
            const matchText = (mId + ' ' + mName + ' ' + (mFamily || '') + ' ' + (mDesc || '') + ' ' + pId + ' ' + (p.name || '')).toLowerCase();
            if (!matchText.includes(query)) {
              continue;
            }
          }

          allModels.push({
            id: mId,
            name: mName,
            providerId: p.id || pId,
            providerName: p.name || pId,
            family: mFamily,
            description: mDesc,
            modalities: m.modalities || {},
            toolCall: m.tool_call !== undefined ? Boolean(m.tool_call) : (m.toolCall !== undefined ? Boolean(m.toolCall) : null),
            reasoning: m.reasoning !== undefined ? Boolean(m.reasoning) : null,
            openWeights: m.open_weights !== undefined ? Boolean(m.open_weights) : (m.openWeights !== undefined ? Boolean(m.openWeights) : null),
            limit: m.limit || {},
            cost: m.cost || {}
          });
        }
      }

      let startIndex = 0;
      if (args.cursor) {
        const idx = allModels.findIndex(item => (item.providerId + '/' + item.id) === args.cursor);
        if (idx === -1) {
          throw new Error('Invalid or expired cursor');
        }
        startIndex = idx;
      }

      const sliceItems = allModels.slice(startIndex, startIndex + limit);
      const nextIndex = startIndex + limit;
      const nextCursor = nextIndex < allModels.length ? (allModels[nextIndex].providerId + '/' + allModels[nextIndex].id) : null;

      return guardSize({ items: sliceItems, nextCursor });
    }
  });

  action('getModelDetails', {
    async invoke(args) {
      const catalog = await getCatalog();
      const providerId = String(args.providerId || '').trim().toLowerCase();
      const modelId = String(args.modelId || '').trim().toLowerCase();

      const pKey = Object.keys(catalog).find(k => k.toLowerCase() === providerId || (catalog[k].id && catalog[k].id.toLowerCase() === providerId));
      if (!pKey) {
        throw new Error('Provider not found: ' + args.providerId);
      }
      const p = catalog[pKey];
      const models = p.models || {};

      const mKey = Object.keys(models).find(k => k.toLowerCase() === modelId || (models[k].id && models[k].id.toLowerCase() === modelId));
      if (!mKey) {
        throw new Error('Model not found: ' + args.modelId + ' under provider ' + args.providerId);
      }
      const m = models[mKey];
      const env = Array.isArray(p.env) ? p.env : (p.env ? [p.env] : []);

      const providerMeta = {
        id: p.id || pKey,
        name: p.name || pKey,
        api: p.api ?? null,
        doc: p.doc ?? null,
        npm: p.npm ?? null,
        env
      };

      const modelCopy = JSON.parse(JSON.stringify(m));
      if (!modelCopy.id) modelCopy.id = mKey;
      if (!modelCopy.name) modelCopy.name = mKey;

      return guardSize({
        provider: providerMeta,
        model: modelCopy
      });
    }
  });
});
