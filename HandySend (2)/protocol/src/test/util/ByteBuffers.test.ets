import { describe, it, expect } from '@ohos/hypium';
import {
  CR,
  LF,
  ByteBuffer,
  concatBytes,
  indexOfSequence,
  asciiDecode,
  asciiEncode,
  findCrlf,
  readCrlfLine,
  readCrlfLineAsString
} from '../../main/ets/util/ByteBuffers';

function bytesOf(values: number[]): Uint8Array {
  return new Uint8Array(values);
}

export default function byteBuffersTest() {
  describe('ByteBuffersTest', () => {
    it('concat_joins_chunks', 0, () => {
      const empty: Uint8Array = concatBytes([]);
      expect(empty.length).assertEqual(0);

      const joined: Uint8Array = concatBytes([bytesOf([0x61, 0x62]), bytesOf([]), bytesOf([0x63])]);
      expect(joined.length).assertEqual(3);
      expect(joined[0]).assertEqual(0x61);
      expect(joined[2]).assertEqual(0x63);
    });

    it('indexOfSequence_honours_the_offset', 0, () => {
      const haystack: Uint8Array = asciiEncode('hello world, hello ArkTS');
      expect(indexOfSequence(haystack, asciiEncode('hello'), 0)).assertEqual(0);
      expect(indexOfSequence(haystack, asciiEncode('hello'), 1)).assertEqual(13);
      expect(indexOfSequence(haystack, asciiEncode('nope'), 0)).assertEqual(-1);
      expect(indexOfSequence(haystack, asciiEncode('ArkTS'), 13)).assertEqual(19);
      // A needle longer than the haystack can never match.
      expect(indexOfSequence(bytesOf([0x61]), asciiEncode('ab'), 0)).assertEqual(-1);
      expect(indexOfSequence(haystack, bytesOf([]), 4)).assertEqual(4);
    });

    it('byteBuffer_appends_consumes_and_peekes', 0, () => {
      const buffer: ByteBuffer = new ByteBuffer(4);
      expect(buffer.length).assertEqual(0);

      buffer.append(asciiEncode('GET /api/localsend/'));
      buffer.append(asciiEncode('ping HTTP/1.1'));
      expect(buffer.length).assertEqual(32);

      const view: Uint8Array = buffer.peek();
      expect(asciiDecode(view)).assertEqual('GET /api/localsend/ping HTTP/1.1');
      // peek copies: mutating it must not corrupt the buffer.
      view[0] = 0x58;
      expect(buffer.at(0)).assertEqual(0x47);

      buffer.consume(4);
      expect(buffer.length).assertEqual(28);
      expect(asciiDecode(buffer.peek())).assertEqual(' /api/localsend/ping HTTP/1.1');

      buffer.consume(1000);
      expect(buffer.length).assertEqual(0);
      expect(buffer.peek().length).assertEqual(0);
    });

    it('byteBuffer_slice_is_clamped_and_copied', 0, () => {
      const buffer: ByteBuffer = new ByteBuffer();
      buffer.append(bytesOf([1, 2, 3, 4, 5]));
      const mid: Uint8Array = buffer.slice(1, 4);
      expect(mid.length).assertEqual(3);
      expect(mid[0]).assertEqual(2);
      expect(mid[2]).assertEqual(4);
      expect(buffer.slice(-1, 99).length).assertEqual(5);
      expect(buffer.slice(3, 2).length).assertEqual(0);
      mid[0] = 0xff;
      expect(buffer.at(1)).assertEqual(2);
    });

    it('byteBuffer_findCrlf_and_line_reads', 0, () => {
      const buffer: ByteBuffer = new ByteBuffer();
      buffer.append(asciiEncode('GET /foo HTTP/1.1\r\nHost: 192.168.1.10:53317'));

      expect(findCrlf(buffer, 0)).assertEqual(17);
      const first: string | null = readCrlfLineAsString(buffer);
      expect(first === null).assertFalse();
      if (first !== null) {
        expect(first).assertEqual('GET /foo HTTP/1.1');
      }
      // The request line is gone, the unfinished header stays buffered.
      expect(buffer.length).assertEqual(24);
      expect(readCrlfLine(buffer) === null).assertTrue();
      expect(buffer.length).assertEqual(24);

      buffer.append(asciiEncode('\r\n\r\n'));
      const header: Uint8Array | null = readCrlfLine(buffer);
      expect(header !== null).assertTrue();
      if (header !== null) {
        expect(asciiDecode(header)).assertEqual('Host: 192.168.1.10:53317');
      }
      // A blank CRLF is an empty line, not a missing one.
      const blank: Uint8Array | null = readCrlfLine(buffer);
      expect(blank !== null).assertTrue();
      if (blank !== null) {
        expect(blank.length).assertEqual(0);
      }
      expect(buffer.length).assertEqual(0);
    });

    it('byteBuffer_line_spans_two_appends', 0, () => {
      const buffer: ByteBuffer = new ByteBuffer();
      buffer.append(bytesOf([0x41, CR]));
      expect(readCrlfLine(buffer) === null).assertTrue();
      buffer.append(bytesOf([LF, 0x42]));
      const line: Uint8Array | null = readCrlfLine(buffer);
      expect(line !== null).assertTrue();
      if (line !== null) {
        expect(line.length).assertEqual(1);
        expect(line[0]).assertEqual(0x41);
      }
      expect(buffer.length).assertEqual(1);
      expect(buffer.at(0)).assertEqual(0x42);
    });

    it('ascii_round_trip', 0, () => {
      expect(asciiDecode(bytesOf([]))).assertEqual('');
      expect(asciiEncode('').length).assertEqual(0);
      const text: string = 'HTTP/1.1 200 OK';
      expect(asciiDecode(asciiEncode(text))).assertEqual(text);
    });
  });
}
