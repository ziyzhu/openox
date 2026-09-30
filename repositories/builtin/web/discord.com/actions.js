const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();
const sleep = ms => new Promise(resolve => window.setTimeout(resolve, ms));
const snowflake = value => /^[0-9]{5,30}$/.test(String(value ?? ""));

function signedInRoot() {
  return document.querySelector('[data-list-id="guildsnav"], [aria-label="Servers sidebar"]');
}

function loginVisible() {
  return location.pathname.startsWith('/login') || !!document.querySelector('input[name="email"], input[autocomplete="username"]');
}

async function waitFor(predicate, message, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await sleep(100);
  }
  throw new Error(message);
}

function requireSignedIn() {
  if (signedInRoot()) return;
  if (loginVisible()) throw new Error('Discord sign-in is required.');
  throw new Error('Discord did not reach a recognizable signed-in state.');
}

function parseServerLabel(raw) {
  let label = cleanText(raw);
  const unread = /^Unread messages, /i.test(label) || /^\d+ mentions?, /i.test(label);
  const mention = label.match(/^(\d+) mentions?, /i);
  label = label.replace(/^Unread messages, /i, '').replace(/^\d+ mentions?, /i, '').replace(/, Voice call active$/i, '');
  return {name: label, unread, mentionCount: mention ? Number(mention[1]) : 0};
}

function guildItem(serverId) {
  return document.querySelector('[data-list-item-id="guildsnav___' + CSS.escape(serverId) + '"]');
}

async function openServer(serverId) {
  if (!snowflake(serverId)) throw new Error('Invalid Discord server ID.');
  requireSignedIn();
  if (!location.pathname.startsWith('/channels/' + serverId + '/')) {
    const item = guildItem(serverId);
    if (!item) throw new Error('That server is not currently available in the rendered Discord sidebar.');
    item.click();
  }
  await waitFor(() => location.pathname.startsWith('/channels/' + serverId + '/'), 'Discord did not open the requested server.');
  await waitFor(() => document.querySelector('[data-list-item-id^="channels___"]'), 'Discord channels did not become ready.');
}

async function openChannel(serverId, channelId) {
  if (!snowflake(channelId)) throw new Error('Invalid Discord channel ID.');
  await openServer(serverId);
  const wanted = '/channels/' + serverId + '/' + channelId;
  if (location.pathname !== wanted) {
    const link = [...document.querySelectorAll('a[href^="/channels/' + CSS.escape(serverId) + '/"]')]
      .find(a => a.getAttribute('href') === wanted);
    if (!link) throw new Error('That channel is not currently available in the rendered server channel list.');
    link.click();
  }
  await waitFor(() => location.pathname === wanted, 'Discord did not open the requested channel.');
  await waitFor(() => document.querySelector('main, [data-list-id="chat-messages"]'), 'Discord channel did not become ready.');
}

window.ox.install(({ action }) => {
  action('getSignInUrl', {
    async invoke() {
      return {url: 'https://discord.com/login'};
    },
  });

  action('getSignInState', {
    async invoke() {
      if (signedInRoot()) return {signedIn: true};
      if (loginVisible()) return {signedIn: false};
      throw new Error('Discord sign-in state is not recognizable.');
    },
  });

  action('listServers', {
    async invoke() {
      await waitFor(() => signedInRoot() || loginVisible(), 'Discord did not become ready.');
      requireSignedIn();
      const items = [...signedInRoot().querySelectorAll('[role="treeitem"][data-list-item-id^="guildsnav___"]')]
        .map(node => {
          const key = node.getAttribute('data-list-item-id') || '';
          const id = key.slice('guildsnav___'.length);
          if (!snowflake(id)) return null;
          const parsed = parseServerLabel(node.getAttribute('aria-label') || node.textContent);
          return {id, name: parsed.name, unread: parsed.unread, mentionCount: parsed.mentionCount, selected: node.getAttribute('aria-selected') === 'true', url: 'https://discord.com/channels/' + id};
        })
        .filter(Boolean);
      return {items, scope: 'rendered', complete: false};
    },
  });

  action('listChannels', {
    async invoke(args) {
      const serverId = String(args.serverId);
      await openServer(serverId);
      const seen = new Set();
      const items = [...document.querySelectorAll('[data-list-item-id^="channels___"]')].map(node => {
        const key = node.getAttribute('data-list-item-id') || '';
        const id = key.slice('channels___'.length);
        if (!snowflake(id) || seen.has(id)) return null;
        seen.add(id);
        const raw = cleanText(node.getAttribute('aria-label') || node.textContent);
        const link = node.matches('a') ? node : node.querySelector('a[href^="/channels/"]');
        const href = link?.getAttribute('href') || null;
        let type = 'other';
        if (/\(text channel\)/i.test(raw) || href) type = 'text';
        else if (/\(voice channel\)/i.test(raw)) type = 'voice';
        else if (/\(category\)/i.test(raw)) type = 'category';
        const name = raw.replace(/ \((text|voice) channel\).*$/i, '').replace(/ \(category\)$/i, '');
        return {id, name, type, private: /Private Channel|locked/i.test(raw), selected: href != null && location.pathname === href, url: href ? new URL(href, location.origin).href : null};
      }).filter(Boolean);
      return {serverId, items, scope: 'rendered', complete: false};
    },
  });

  action('searchMessages', {
    async invoke(args) {
      const serverId = String(args.serverId);
      const query = cleanText(args.query);
      if (!query || query.length > 200) throw new Error('Search query must contain 1 to 200 characters.');
      await openServer(serverId);
      const editor = await waitFor(() => document.querySelector('[role="combobox"][aria-label^="Search"]'), 'Discord search did not become ready.');
      editor.focus();
      const fiberKey = Object.getOwnPropertyNames(editor).find(key => key.startsWith('__reactFiber'));
      let fiber = editor[fiberKey];
      let slate = null;
      for (let index = 0; fiber && index < 16; index += 1, fiber = fiber.return) {
        const value = fiber.memoizedProps?.value;
        if (value && typeof value.insertText === 'function' && Array.isArray(value.children)) { slate = value; break; }
      }
      if (!slate) throw new Error('Discord search editor state is unavailable.');
      const prior = String(slate.children?.[0]?.children?.[0]?.text || '');
      slate.selection = {anchor: {path: [0, 0], offset: 0}, focus: {path: [0, 0], offset: prior.length}};
      if (prior) slate.deleteFragment();
      slate.insertText(query);
      await waitFor(() => cleanText(editor.textContent) === query, 'Discord search query could not be entered.', 3000);
      const priorSection = document.querySelector('section[aria-label="Search Results"]');
      const snapshot = section => section ? cleanText(section.textContent) + '|' + [...section.querySelectorAll('[id^="search-result-"]')].map(node => node.id).join(',') : '';
      const priorSnapshot = snapshot(priorSection);
      let sawSearching = false;
      editor.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true, cancelable: true}));
      const results = await waitFor(() => {
        const section = document.querySelector('section[aria-label="Search Results"]');
        if (!section) return null;
        if (/Searching/i.test(section.textContent || '')) { sawSearching = true; return null; }
        if (!sawSearching && snapshot(section) === priorSnapshot) return null;
        return section;
      }, 'Discord search did not finish.', 22000);
      const text = cleanText(results.textContent);
      const totalMatch = text.match(/^([0-9,]+) Results?/i);
      const total = /No Results/i.test(text) ? 0 : totalMatch ? Number(totalMatch[1].replace(/,/g, '')) : null;
      if (total == null) throw new Error('Discord search returned an unrecognized result count.');
      const nodes = [...results.querySelectorAll('[id^="search-result-"]')];
      const items = nodes.map(node => {
        const id = node.id.slice('search-result-'.length);
        if (!snowflake(id)) return null;
        let fiber = node[Object.getOwnPropertyNames(node).find(key => key.startsWith('__reactFiber'))];
        let message = null;
        for (let index = 0; fiber && index < 16; index += 1, fiber = fiber.return) {
          if (fiber.memoizedProps?.message?.id === id) { message = fiber.memoizedProps.message; break; }
        }
        const channelId = String(message?.channel_id || '');
        if (!snowflake(channelId)) throw new Error('Discord search result channel metadata is unavailable.');
        const username = node.querySelector('[id^="message-username-"]');
        const time = node.querySelector('time[datetime]');
        const content = node.querySelector('[id^="message-content-"]');
        return {
          id,
          channelId,
          author: cleanText(username?.textContent) || null,
          timestamp: time?.getAttribute('datetime') || null,
          content: cleanText(message?.content ?? content?.textContent ?? ''),
          url: 'https://discord.com/channels/' + serverId + '/' + channelId + '/' + id,
        };
      }).filter(Boolean);
      if (total > items.length) throw new Error('Discord found more results than the rendered page can return. Use a narrower query.');
      return {serverId, query, total, items, nextCursor: null};
    },
  });

  action('getMessages', {
    async invoke(args) {
      const serverId = String(args.serverId);
      const channelId = String(args.channelId);
      const limit = Math.max(1, Math.min(100, Number(args.limit ?? 50)));
      await openChannel(serverId, channelId);
      await waitFor(() => document.querySelector('li[id^="chat-messages-"]') || document.querySelector('[data-list-id="chat-messages"]'), 'Discord messages did not become ready.');
      let lastAuthor = null;
      const all = [...document.querySelectorAll('li[id^="chat-messages-"]')].map(node => {
        const username = node.querySelector('[id^="message-username-"]');
        if (username) lastAuthor = cleanText(username.textContent);
        const time = node.querySelector('time[datetime]');
        const content = node.querySelector('[id^="message-content-"]');
        const id = node.id.split('-').pop();
        if (!snowflake(id)) return null;
        const attachments = [...node.querySelectorAll('a[href*="cdn.discordapp.com/attachments/"], a[href*="media.discordapp.net/attachments/"]')]
          .map(link => ({url: link.href, name: cleanText(link.getAttribute('download') || link.textContent) || null}))
          .filter((item, index, array) => array.findIndex(other => other.url === item.url) === index)
          .slice(0, 20);
        return {id, author: lastAuthor, timestamp: time?.getAttribute('datetime') || null, content: cleanText(content?.textContent || ''), attachments, url: 'https://discord.com/channels/' + serverId + '/' + channelId + '/' + id};
      }).filter(Boolean);
      return {serverId, channelId, items: all.slice(-limit), scope: 'rendered', complete: false};
    },
  });
});
