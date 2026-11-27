import { readFile, writeFile, unlink } from 'node:fs/promises';

// Assemble the GIF frames exported by the Windows packager, preserving each
// frame's own palette and compressed pixels. No image generation or redraw.
const root = new URL('../', import.meta.url);
const delays = [75, 60, 6, 8, 7, 6, 65, 60];
const actions = ['Thinking', 'Reading', 'Typing', 'Replying', 'Celebrating', 'Focusing'];

function imageBlock(bytes) {
  if (!bytes.subarray(0, 6).toString('ascii').startsWith('GIF')) throw new Error('Invalid GIF');
  const globalSize = bytes[10] & 7;
  let position = 13;
  const globalPalette = bytes[10] & 128 ? bytes.subarray(position, position += 3 * (2 ** (globalSize + 1))) : null;
  const skipBlocks = () => { while (bytes[position]) position += 1 + bytes[position]; position++; };
  while (position < bytes.length) {
    const marker = bytes[position++];
    if (marker === 0x21) { position++; skipBlocks(); continue; }
    if (marker === 0x3b) break;
    if (marker !== 0x2c) throw new Error('Invalid GIF image block');
    const descriptor = Buffer.from(bytes.subarray(position - 1, position + 9));
    position += 9;
    const localSize = descriptor[9] & 7;
    const hasLocal = !!(descriptor[9] & 128);
    const palette = hasLocal ? bytes.subarray(position, position += 3 * (2 ** (localSize + 1))) : globalPalette;
    if (!palette) throw new Error('Missing GIF palette');
    descriptor[9] = (descriptor[9] & 0x78) | 128 | (hasLocal ? localSize : globalSize);
    const pixelsStart = position++;
    skipBlocks();
    return Buffer.concat([descriptor, palette, bytes.subarray(pixelsStart, position)]);
  }
  throw new Error('No GIF image');
}

for (const [character, prefix] of [['codex', 'CodePax'], ['claude', 'Claude']]) {
  for (const action of actions) {
    const inputs = Array.from({ length: 8 }, (_, i) => new URL(`work/animation-preview/${prefix}${action}${i}.gif`, root));
    const frames = await Promise.all(inputs.map(path => readFile(path)));
    const screen = Buffer.from(frames[0].subarray(6, 13));
    screen[4] = 0x70; screen[5] = 0; screen[6] = 0;
    const parts = [Buffer.from('GIF89a'), screen];
    if (action !== 'Celebrating') parts.push(Buffer.from([0x21,0xff,0x0b,...Buffer.from('NETSCAPE2.0'),3,1,0,0,0]));
    frames.forEach((frame, index) => {
      parts.push(Buffer.from([0x21,0xf9,4,4,delays[index] & 255,delays[index] >> 8,0,0]), imageBlock(frame));
    });
    parts.push(Buffer.from([0x3b]));
    const output = new URL(`design/brand/animation/${character}-${action.toLowerCase()}-preview.gif`, root);
    await writeFile(output, Buffer.concat(parts));
    await Promise.all(inputs.map(path => unlink(path)));
  }
}
console.log('Exported 12 eight-frame motion previews.');
