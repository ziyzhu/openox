const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function sessionState() {
  const response = await fetch('/api/usage?granularity=day', {credentials: 'include', cache: 'no-store'});
  const contentType = response.headers.get('content-type') || '';
  const text = await response.text();
  if (response.status === 200 && contentType.includes('application/json')) {
    const data = JSON.parse(text);
    if (Array.isArray(data?.buckets)) return {signedIn: true};
  }
  if (response.status === 401 && contentType.includes('application/problem+json')) {
    const data = JSON.parse(text);
    if (data?.code === 'unauthenticated') return {signedIn: false};
  }
  throw new Error('Unrecognized TypeSafe session response');
}

function hydrationScript() {
  return Array.from(document.scripts).map(script => script.textContent || '').find(text => text.includes('initialUser') && text.includes('availableModels')) || null;
}

function decodeEscapedJson(fragment) {
  return JSON.parse(fragment.replaceAll('\\"', '"').replaceAll('\\n', '\n').replaceAll('\\\\', '\\'));
}

async function readyHydration() {
  const deadline = Date.now() + 8000;
  do {
    const text = hydrationScript();
    if (text) return text;
    await sleep(100);
  } while (Date.now() < deadline);
  throw new Error('TypeSafe account data did not become ready');
}

async function currentUser() {
  const text = await readyHydration();
  const marker = text.indexOf('initialUser');
  const start = text.indexOf(':', marker) + 1;
  const flags = text.indexOf('flags', start);
  if (marker < 0 || start < 1 || flags < 0) throw new Error('TypeSafe account contract changed');
  const user = decodeEscapedJson(text.slice(start, flags - 3));
  if (!user || typeof user.human_name !== 'string' || typeof user.email !== 'string' || !Array.isArray(user.org_memberships)) throw new Error('Unexpected TypeSafe account data');
  return {
    name: user.human_name,
    email: user.email,
    organizations: user.org_memberships.map(membership => {
      const org = membership?.org;
      if (!org || typeof org.name !== 'string' || typeof org.billing_plan !== 'string') throw new Error('Unexpected TypeSafe organization data');
      return {name: org.name, plan: org.billing_plan, isAdmin: membership.is_admin === true, isActive: org.is_active === true};
    })
  };
}

async function models() {
  const text = await readyHydration();
  const marker = text.indexOf('availableModels');
  const start = text.indexOf('[', marker);
  const end = text.indexOf(']', start);
  if (marker < 0 || start < 0 || end < 0) throw new Error('TypeSafe model list contract changed');
  const list = decodeEscapedJson(text.slice(start, end + 1));
  if (!Array.isArray(list) || list.some(model => typeof model !== 'string')) throw new Error('Unexpected TypeSafe model list');
  return {models: Array.from(new Set(list))};
}

function questionBody(question) {
  const body = {type: question.type, instructions: question.instructions};
  if (question.type === 'noul') {
    if (question.options || question.levels) throw new Error('Noul questions cannot include options or levels');
    if (question.trueMeaning !== undefined || question.falseMeaning !== undefined) body.criteria = {true: question.trueMeaning || null, false: question.falseMeaning || null};
  } else if (question.type === 'choice') {
    if (!question.options || Object.keys(question.options).length < 2) throw new Error('Choice questions require at least two options');
    body.criteria = question.options;
  } else if (question.type === 'score') {
    if (!Array.isArray(question.levels) || question.levels.length < 2) throw new Error('Score questions require at least two levels');
    body.criteria = question.levels;
  } else throw new Error('Unsupported TypeSafe question type');
  return body;
}

function normalizeEvaluation(data) {
  if (!data || typeof data.model !== 'string' || !data.answers || typeof data.answers !== 'object' || !data.usage) throw new Error('Unexpected TypeSafe evaluation response');
  const answers = Object.entries(data.answers).map(([id, answer]) => {
    if (!answer || !['noul', 'choice', 'score'].includes(answer.type)) throw new Error('Unexpected TypeSafe answer');
    const out = {id, type: answer.type};
    for (const key of ['noul', 'choice', 'score', 'confidence']) if (answer[key] !== undefined) out[key] = answer[key];
    if (answer.probabilities !== undefined) out.probabilities = answer.probabilities;
    if (answer.legend !== undefined) out.legend = Object.fromEntries(Object.entries(answer.legend).map(([key, value]) => [key, String(value)]));
    return out;
  });
  return {model: data.model, answers, inputTokens: Number(data.usage.input_tokens || 0), outputTokens: Number(data.usage.output_tokens || 0)};
}

async function evaluate(state, questions, model = 'jev-latest') {
  const mapped = {};
  for (const question of questions) {
    if (mapped[question.id]) throw new Error('Question IDs must be unique');
    mapped[question.id] = questionBody(question);
  }
  const response = await fetch('/api/evaluation', {
    method: 'POST',
    credentials: 'include',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({state, model, questions: mapped})
  });
  const text = await response.text();
  let data = null;
  try { data = JSON.parse(text); } catch {}
  if (!response.ok) {
    const message = data?.detail || data?.title || data?.message || ('HTTP ' + response.status);
    throw new Error('TypeSafe evaluation failed: ' + (typeof message === 'string' ? message : JSON.stringify(message)));
  }
  return normalizeEvaluation(data);
}

window.ox.install(({action}) => {
  action('getSignInUrl', {async invoke() { return {url: 'https://console.typesafe.ai/login?returnTo=%2Fplayground'}; }});
  action('getSignInState', {async invoke() { return sessionState(); }});
  action('getCurrentUser', {async invoke() { return currentUser(); }});
  action('listModels', {async invoke() { return models(); }});
  action('evaluateState', {async invoke({state, questions, model = 'jev-latest'}) { return evaluate(state, questions, model); }});
  action('judgeYesNo', {async invoke({state, question, trueMeaning, falseMeaning, model = 'jev-latest'}) {
    const result = await evaluate(state, [{id: 'answer', type: 'noul', instructions: question, trueMeaning, falseMeaning}], model);
    const answer = result.answers[0];
    return {model: result.model, probabilityYes: answer.noul, inputTokens: result.inputTokens, outputTokens: result.outputTokens};
  }});
  action('chooseOption', {async invoke({state, question, options, model = 'jev-latest'}) {
    const result = await evaluate(state, [{id: 'answer', type: 'choice', instructions: question, options}], model);
    const answer = result.answers[0];
    return {model: result.model, choice: answer.choice, confidence: answer.confidence, probabilities: answer.probabilities, inputTokens: result.inputTokens, outputTokens: result.outputTokens};
  }});
  action('scoreState', {async invoke({state, question, levels, model = 'jev-latest'}) {
    const result = await evaluate(state, [{id: 'answer', type: 'score', instructions: question, levels}], model);
    const answer = result.answers[0];
    return {model: result.model, score: answer.score, confidence: answer.confidence, probabilities: answer.probabilities, legend: answer.legend, inputTokens: result.inputTokens, outputTokens: result.outputTokens};
  }});
});
