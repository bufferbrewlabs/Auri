import 'package:auri/features/read_aloud/domain/reading_timeline.dart';
import 'package:auri/features/read_aloud/domain/text_chunk.dart';
import 'package:auri/features/read_aloud/domain/word_timing.dart';
import 'package:flutter_test/flutter_test.dart';

const _ms = Duration(milliseconds: 1);

// Text estimates are 65 ms a character: c0 is 650 ms, c1 is 1300 ms.
const _c0 = TextChunk(index: 0, start: 0, end: 10, text: 'aaaa bbbbb');
const _c1 = TextChunk(
  index: 1,
  start: 11,
  end: 31,
  text: 'ccccc ddddd eeeeeeee',
);

void main() {
  late ReadingTimeline timeline;

  setUp(() => timeline = ReadingTimeline(const [_c0, _c1]));

  group('before any audio is measured', () {
    test('is estimated from text length', () {
      expect(timeline.estimated, isTrue);
      expect(timeline.duration(_c0), _ms * 650);
      expect(timeline.total, _ms * 1950);
    });

    test('chunkAt finds the chunk ending after an offset', () {
      expect(timeline.chunkAt(0), _c0);
      expect(timeline.chunkAt(9), _c0);
      expect(timeline.chunkAt(10), _c1);
      expect(timeline.chunkAt(999), _c1);
    });

    test('localTime is proportional within a chunk and clamped', () {
      expect(timeline.localTime(_c0, 0), Duration.zero);
      expect(timeline.localTime(_c0, 5), _ms * 325);
      expect(timeline.localTime(_c0, 50), _ms * 650);
      expect(timeline.localTime(_c1, 3), Duration.zero);
    });

    test('offsetAt is proportional and stays inside the chunk', () {
      expect(timeline.offsetAt(_c0, Duration.zero), 0);
      expect(timeline.offsetAt(_c0, _ms * 325), 5);
      expect(timeline.offsetAt(_c0, const Duration(seconds: 10)), 9);
    });

    test('elapsed adds whole earlier chunks to the local time', () {
      expect(timeline.elapsed(0), Duration.zero);
      expect(timeline.elapsed(15), _ms * (650 + 260));
      expect(timeline.elapsed(0, active: _c1, position: _ms * 100), _ms * 750);
    });

    test('seek maps a time to an offset and clamps past the end', () {
      expect(timeline.seek(Duration.zero), 0);
      expect(timeline.seek(_ms * 325), 5);
      expect(timeline.seek(_ms * 1300), 11 + 10);
      expect(timeline.seek(const Duration(minutes: 5)), _c1.end - 1);
    });

    test('seek and elapsed round-trip at chunk starts', () {
      for (final chunk in timeline.chunks) {
        expect(timeline.seek(timeline.elapsed(chunk.start)), chunk.start);
      }
    });
  });

  group('measure', () {
    test('real durations replace estimates', () {
      timeline.measure(_c0, const Duration(seconds: 1), const []);
      expect(timeline.duration(_c0), const Duration(seconds: 1));
      expect(timeline.estimated, isTrue);
      timeline.measure(_c1, const Duration(seconds: 2), const []);
      expect(timeline.estimated, isFalse);
      expect(timeline.total, const Duration(seconds: 3));
      expect(timeline.seek(const Duration(milliseconds: 1500)), 11 + 5);
    });

    test('missing or zero durations keep the estimate', () {
      timeline.measure(_c0, null, const []);
      timeline.measure(_c1, Duration.zero, const []);
      expect(timeline.estimated, isTrue);
      expect(timeline.total, _ms * 1950);
    });
  });

  group('with word timings', () {
    const words = [
      AlignedWord(span: BodySpan(11, 16), start: Duration(milliseconds: 100)),
      AlignedWord(span: BodySpan(17, 22), start: Duration(milliseconds: 500)),
      AlignedWord(span: BodySpan(23, 31), start: Duration(milliseconds: 900)),
    ];

    setUp(() => timeline.measure(_c1, const Duration(seconds: 2), words));

    test('localTime is the start of the word at the offset', () {
      expect(timeline.localTime(_c1, 12), _ms * 100);
      expect(timeline.localTime(_c1, 16), _ms * 500);
      expect(timeline.localTime(_c1, 20), _ms * 500);
      expect(timeline.localTime(_c1, 40), _ms * 900);
    });

    test('offsetAt is the start of the word being spoken', () {
      expect(timeline.offsetAt(_c1, Duration.zero), _c1.start);
      expect(timeline.offsetAt(_c1, _ms * 100), 11);
      expect(timeline.offsetAt(_c1, _ms * 899), 17);
      expect(timeline.offsetAt(_c1, const Duration(seconds: 5)), 23);
    });

    test('seek lands on word starts', () {
      expect(timeline.seek(_ms * (650 + 600)), 17);
    });
  });
}
