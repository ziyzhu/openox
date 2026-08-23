const field = document.querySelector("#ox-field");
const context = field.getContext("2d");
const sideLength = 18;
const restDuration = 720;
const recoveryGenerationCount = 2;
const generationDurations = [230, 184, 150, 121, 98, 81, 63, 55, 48];
const primary = [255, 165, 0];
const initialGeneration = new Set([
  "7,7", "10,7",
  "7,8", "8,8", "9,8", "10,8",
  "8,9", "9,9",
  "8,10", "9,10",
]);
const initialFrame = new Set(
  Array.from({ length: 16 }, (_, index) => `${7 + index % 4},${7 + Math.floor(index / 4)}`),
);
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

let pulseGenerations = [initialGeneration];
let animationStartedAt;
let currentFrame = [initialGeneration, initialGeneration, 0];

function wrap(coordinate) {
  return (coordinate + sideLength) % sideLength;
}

function nextGeneration(generation) {
  const neighborCounts = new Map();

  for (const position of generation) {
    const [x, y] = position.split(",").map(Number);
    for (let yOffset = -1; yOffset <= 1; yOffset += 1) {
      for (let xOffset = -1; xOffset <= 1; xOffset += 1) {
        if (xOffset === 0 && yOffset === 0) continue;
        const neighbor = `${wrap(x + xOffset)},${wrap(y + yOffset)}`;
        neighborCounts.set(neighbor, (neighborCounts.get(neighbor) ?? 0) + 1);
      }
    }
  }

  return new Set(
    [...neighborCounts]
      .filter(([position, count]) => count === 2 && !generation.has(position))
      .map(([position]) => position),
  );
}

function touchesBorder(generation) {
  return [...generation].some((position) => {
    const [x, y] = position.split(",").map(Number);
    return x === 0 || y === 0 || x === sideLength - 1 || y === sideLength - 1;
  });
}

while (!touchesBorder(pulseGenerations.at(-1))) {
  pulseGenerations.push(nextGeneration(pulseGenerations.at(-1)));
}
for (let index = 0; index < recoveryGenerationCount; index += 1) {
  pulseGenerations.push(nextGeneration(pulseGenerations.at(-1)));
}

const pulseDuration = generationDurations
  .slice(0, pulseGenerations.length - 1)
  .reduce((total, duration) => total + duration, 0);
const cycleDuration = restDuration + pulseDuration;

function expanded(generation) {
  const nearby = new Set();

  for (const position of generation) {
    const [x, y] = position.split(",").map(Number);
    for (let yOffset = -2; yOffset <= 2; yOffset += 1) {
      for (let xOffset = -2; xOffset <= 2; xOffset += 1) {
        nearby.add(`${wrap(x + xOffset)},${wrap(y + yOffset)}`);
      }
    }
  }

  return nearby;
}

function resize() {
  const size = field.getBoundingClientRect().width;
  const scale = window.devicePixelRatio || 1;
  field.width = Math.round(size * scale);
  field.height = Math.round(size * scale);
  context.setTransform(scale, 0, 0, scale, 0, 0);
  draw(...currentFrame);
}

function opacity(position, generation, nearby, nearbyOpacity) {
  if (generation.has(position)) return 1;
  if (generation === initialGeneration && initialFrame.has(position)) return 0.055;
  if (nearby.has(position)) return nearbyOpacity;
  return 0;
}

function draw(fromGeneration, toGeneration = fromGeneration, progress = 0) {
  const size = field.getBoundingClientRect().width;
  const cellSize = size / sideLength;
  const gap = Math.max(0.45, Math.min(2.2, cellSize * 0.12));
  const radius = Math.max(0.5, (cellSize - gap) * 0.24);
  const fromNearby = expanded(fromGeneration);
  const toNearby = expanded(toGeneration);
  const fromNearbyOpacity = fromGeneration === initialGeneration ? 0 : 0.055;
  const toNearbyOpacity = toGeneration === initialGeneration ? 0 : 0.055;

  context.clearRect(0, 0, size, size);

  for (let y = 0; y < sideLength; y += 1) {
    for (let x = 0; x < sideLength; x += 1) {
      const position = `${x},${y}`;
      const fromOpacity = opacity(position, fromGeneration, fromNearby, fromNearbyOpacity);
      const toOpacity = opacity(position, toGeneration, toNearby, toNearbyOpacity);
      const cellOpacity = fromOpacity + (toOpacity - fromOpacity) * progress;
      if (cellOpacity === 0) continue;

      context.fillStyle = `rgba(${primary.join(",")},${cellOpacity})`;
      context.beginPath();
      context.roundRect(
        x * cellSize + gap / 2,
        y * cellSize + gap / 2,
        cellSize - gap,
        cellSize - gap,
        radius,
      );
      context.fill();
    }
  }
}

function easeOutCubic(progress) {
  return 1 - Math.pow(1 - progress, 3);
}

function frameAt(elapsed) {
  if (elapsed < restDuration) return [initialGeneration, initialGeneration, 0];

  let pulseElapsed = elapsed - restDuration;
  for (let index = 0; index < pulseGenerations.length - 1; index += 1) {
    const duration = generationDurations[index];
    if (pulseElapsed < duration) {
      return [
        pulseGenerations[index],
        pulseGenerations[index + 1],
        easeOutCubic(pulseElapsed / duration),
      ];
    }
    pulseElapsed -= duration;
  }

  return [pulseGenerations.at(-1), pulseGenerations.at(-1), 0];
}

function animate(timestamp) {
  if (reducedMotion.matches) {
    draw(initialGeneration);
    return;
  }

  animationStartedAt ??= timestamp;
  currentFrame = frameAt((timestamp - animationStartedAt) % cycleDuration);
  draw(...currentFrame);

  requestAnimationFrame(animate);
}

new ResizeObserver(resize).observe(field);
reducedMotion.addEventListener("change", () => {
  animationStartedAt = undefined;
  currentFrame = [initialGeneration, initialGeneration, 0];
  requestAnimationFrame(animate);
});
requestAnimationFrame(animate);
