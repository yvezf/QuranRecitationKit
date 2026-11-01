#!/usr/bin/env python3
"""Deterministic ayah-based matching index. Arabic input remains verbatim Tanzil text."""
from __future__ import annotations
import argparse, collections, hashlib, heapq, json, os, re, sys, tempfile, unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
import sentencepiece as spm
ROOT=Path(__file__).resolve().parents[2] / 'bindings/swift'
QURAN_PATH=ROOT/'Tools/data/quran-uthmani.json'
TOKENIZER_PATH=ROOT/'Tools/vendor/tokenizer.model'
OUTPUT=ROOT/'Sources/QuranRecitationKit/Resources'
VOCAB_PATH=OUTPUT/'vocab.json'
EXPECTED_AYAH_COUNT=6236
EXPECTED_SURAH_COUNT=114
EXPECTED_TOKENIZER_SIZE=254806
EXPECTED_TOKENIZER_SHA256='1fcfa104fa448c979cc2537788947c6516827f403ecdc55c4895b77d28630ba4'
EXPECTED_VOCAB_SIZE=21062
EXPECTED_VOCAB_SHA256='c55877f3bff8bc3aaefc160e8c2fb88cb349088d092513d40210ccfe535e671b'
EXPECTED_SENTENCEPIECE_VERSION='0.2.1'
class GenerationError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def normalize_arabic(text: str) -> str:
    """Exact scalar-level port of ArabicNormalizer.swift."""

    folded: list[str] = []
    replacements = {
        0x0623: 0x0627,  # أ -> ا
        0x0625: 0x0627,  # إ -> ا
        0x0622: 0x0627,  # آ -> ا
        0x0671: 0x0627,  # ٱ -> ا
        0x0629: 0x0647,  # ة -> ه
        0x0649: 0x064A,  # ى -> ي
    }
    for character in text:
        value = ord(character)
        if (
            value in (0xFEFF, 0x0640, 0x0670)
            or 0x0610 <= value <= 0x061A
            or 0x064B <= value <= 0x065F
            or 0x06D6 <= value <= 0x06DE
            or 0x06DF <= value <= 0x06ED
        ):
            continue
        folded.append(chr(replacements.get(value, value)))
    return " ".join("".join(folded).split())


def scalar_tokens(text: str) -> list[str]:
    """Mirror CharacterSet.whitespacesAndNewlines scalar tokenization."""

    result: list[str] = []
    current: list[str] = []
    for character in text:
        if character.isspace():
            if current:
                result.append("".join(current))
                current.clear()
        else:
            current.append(character)
    if current:
        result.append("".join(current))
    return result


def is_letter_or_number(character: str) -> bool:
    return unicodedata.category(character)[0] in ("L", "N")


def is_standalone_mark(token: str) -> bool:
    return not any(is_letter_or_number(character) for character in token)


def weighted_units(token: str) -> float:
    total = 0.0
    for character in token:
        value = ord(character)
        category = unicodedata.category(character)
        if value == 0x0640:
            total += 0.35
        elif category.startswith("M"):
            continue
        elif category.startswith("L"):
            total += 1.0
        elif category.startswith("N"):
            total += 0.75
        else:
            total += 0.3
    return max(0.3, total)


@dataclass(frozen=True)
class SemanticWord:
    source: str
    ordinal: int
    units: float


@dataclass(frozen=True)
class CanonicalLine:
    index: int
    surah: int
    ayah: int
    words: tuple[str, ...]
    tokens: tuple[int, ...]


def semantic_words(text: str) -> list[SemanticWord]:
    """Return semantic words with stable ordinals.

    The display source attaches a standalone waqf/sajdah glyph to the preceding display
    word without changing that word's width or ordinal.  The recognition map
    omits that display-only glyph, which ArabicNormalizer also removes.
    """

    result: list[SemanticWord] = []
    for token in scalar_tokens(text):
        if is_standalone_mark(token) and result:
            continue
        result.append(
            SemanticWord(
                source=token,
                ordinal=len(result),
                units=weighted_units(token),
            )
        )
    return result


def cumulative_ends(chunks: Iterable[list[int]]) -> tuple[list[int], list[int]]:
    flattened: list[int] = []
    ends: list[int] = []
    for chunk in chunks:
        if not chunk:
            raise GenerationError("a semantic Quran word encoded to zero tokens")
        flattened.extend(chunk)
        ends.append(len(flattened))
    return flattened, ends


def sequence_edit_distance(lhs: tuple[Any, ...], rhs: tuple[Any, ...]) -> int:
    """Exact Levenshtein distance via Myers' arbitrary-width bit-vector."""

    if not lhs:
        return len(rhs)
    if not rhs:
        return len(lhs)
    if len(lhs) > len(rhs):
        lhs, rhs = rhs, lhs

    equality_masks: dict[Any, int] = {}
    for index, value in enumerate(lhs):
        equality_masks[value] = equality_masks.get(value, 0) | (1 << index)

    mask = (1 << len(lhs)) - 1
    high_bit = 1 << (len(lhs) - 1)
    positive = mask
    negative = 0
    score = len(lhs)
    for value in rhs:
        equal = equality_masks.get(value, 0)
        vertical = equal | negative
        horizontal = (((equal & positive) + positive) ^ positive) | equal
        positive_horizontal = negative | ~(horizontal | positive)
        negative_horizontal = positive & horizontal
        if positive_horizontal & high_bit:
            score += 1
        elif negative_horizontal & high_bit:
            score -= 1
        positive_horizontal = ((positive_horizontal << 1) | 1) & mask
        negative_horizontal = (negative_horizontal << 1) & mask
        positive = (negative_horizontal | ~(vertical | positive_horizontal)) & mask
        negative = positive_horizontal & vertical
    return score


def common_prefix_count(lhs: tuple[str, ...], rhs: tuple[str, ...]) -> int:
    count = 0
    for lhs_word, rhs_word in zip(lhs, rhs):
        if lhs_word != rhs_word:
            break
        count += 1
    return count


def common_suffix_count(lhs: tuple[str, ...], rhs: tuple[str, ...]) -> int:
    return common_prefix_count(tuple(reversed(lhs)), tuple(reversed(rhs)))


def spread_postings(postings: list[int], limit: int) -> list[int]:
    """Deterministically retain globally spread members of a sorted posting."""

    if len(postings) <= limit:
        return postings
    selected: list[int] = []
    seen: set[int] = set()
    denominator = max(1, limit - 1)
    for offset in range(limit):
        candidate = postings[(offset * (len(postings) - 1)) // denominator]
        if candidate not in seen:
            selected.append(candidate)
            seen.add(candidate)
    return selected


def feature_posting_limit(feature: tuple[Any, ...]) -> int:
    kind = feature[0]
    if kind in ("opening-2", "ending-2"):
        return 128
    if kind in ("opening-1", "ending-1", "word-bigram"):
        return 96
    if kind == "word":
        return 48
    return 24


def line_features(line: CanonicalLine) -> list[tuple[tuple[Any, ...], int]]:
    words = line.words
    joined = " ".join(words)
    features: dict[tuple[Any, ...], int] = {}

    def add(feature: tuple[Any, ...], weight: int) -> None:
        features[feature] = max(weight, features.get(feature, 0))

    if words:
        add(("opening-1", words[0]), 6)
        add(("ending-1", words[-1]), 6)
    if len(words) >= 2:
        add(("opening-2", words[0], words[1]), 22)
        add(("ending-2", words[-2], words[-1]), 20)
    for index in range(len(words) - 1):
        add(("word-bigram", words[index], words[index + 1]), 14)
    for word in set(words):
        add(("word", word), 3)
    characters = tuple(joined)
    for index in range(len(characters) - 2):
        add(("char-trigram", *characters[index : index + 3]), 2)
    return list(features.items())


def canonical_lines(records: list[list[Any]]) -> list[CanonicalLine]:
    lines: list[CanonicalLine] = []
    for record in records:
        surah, ayah = int(record[0]), int(record[1])
        words: list[str] = record[2]
        token_ids: list[int] = record[3]
        word_token_ends: list[int] = record[4]
        line_word_ends: list[int] = record[5]
        word_start = 0
        for word_end in line_word_ends:
            token_start = 0 if word_start == 0 else word_token_ends[word_start - 1]
            token_end = word_token_ends[word_end - 1]
            lines.append(
                CanonicalLine(
                    index=len(lines),
                    surah=surah,
                    ayah=ayah,
                    words=tuple(words[word_start:word_end]),
                    tokens=tuple(token_ids[token_start:token_end]),
                )
            )
            word_start = word_end
    return lines


def line_similarity_sort_key(
    target: CanonicalLine, candidate: CanonicalLine
) -> tuple[int, int, int, int, int]:
    word_distance = sequence_edit_distance(target.words, candidate.words)
    token_distance = sequence_edit_distance(target.tokens, candidate.tokens)
    word_denominator = max(1, len(target.words), len(candidate.words))
    token_denominator = max(1, len(target.tokens), len(candidate.tokens))
    word_similarity = (word_denominator - word_distance) / word_denominator
    token_similarity = (token_denominator - token_distance) / token_denominator

    target_bigrams = set(zip(target.words, target.words[1:]))
    candidate_bigrams = set(zip(candidate.words, candidate.words[1:]))
    union = target_bigrams | candidate_bigrams
    bigram_similarity = (
        len(target_bigrams & candidate_bigrams) / len(union) if union else 0.0
    )
    prefix_similarity = common_prefix_count(target.words, candidate.words) / max(
        1, min(len(target.words), len(candidate.words))
    )
    suffix_similarity = common_suffix_count(target.words, candidate.words) / max(
        1, min(len(target.words), len(candidate.words))
    )
    score = round(
        1_000_000
        * (
            0.30 * word_similarity
            + 0.25 * token_similarity
            + 0.15 * bigram_similarity
            + 0.18 * prefix_similarity
            + 0.12 * suffix_similarity
        )
    )
    return (
        -score,
        word_distance,
        token_distance,
        abs(len(target.tokens) - len(candidate.tokens)),
        candidate.index,
    )


def build_line_confusers(records: list[list[Any]], maximum: int = 16) -> list[list[int]]:
    """Build deterministic global hard negatives for each canonical  line.

    Same-ayah siblings and the global +/-2 neighborhood are deliberately left
    out because the runtime scorer always adds those cheap local confusers.
    """

    lines = canonical_lines(records)
    inverted: dict[tuple[Any, ...], list[int]] = collections.defaultdict(list)
    feature_cache: list[list[tuple[tuple[Any, ...], int]]] = []
    length_buckets: dict[tuple[int, int], list[int]] = collections.defaultdict(list)
    for line in lines:
        features = line_features(line)
        feature_cache.append(features)
        for feature, _ in features:
            inverted[feature].append(line.index)
        length_buckets[(len(line.words), len(line.tokens) // 2)].append(line.index)

    capped_inverted = {
        feature: spread_postings(postings, feature_posting_limit(feature))
        for feature, postings in inverted.items()
    }
    capped_length_buckets = {
        key: spread_postings(postings, 24)
        for key, postings in length_buckets.items()
    }

    result: list[list[int]] = []
    for target in lines:
        evidence: dict[int, int] = collections.defaultdict(int)
        for feature, weight in feature_cache[target.index]:
            for candidate_index in capped_inverted[feature]:
                evidence[candidate_index] += weight

        word_count = len(target.words)
        token_bucket = len(target.tokens) // 2
        for word_delta in range(-2, 3):
            for token_delta in range(-3, 4):
                bucket = capped_length_buckets.get(
                    (word_count + word_delta, token_bucket + token_delta)
                )
                if bucket:
                    for candidate_index in bucket:
                        evidence.setdefault(candidate_index, 0)

        candidates = [
            candidate_index
            for candidate_index in evidence
            if candidate_index != target.index
            and abs(candidate_index - target.index) > 2
            and (lines[candidate_index].surah, lines[candidate_index].ayah)
            != (target.surah, target.ayah)
        ]
        candidates = heapq.nsmallest(
            32,
            candidates,
            key=lambda candidate_index: (
                -evidence[candidate_index],
                abs(len(lines[candidate_index].tokens) - len(target.tokens)),
                candidate_index,
            ),
        )
        candidates.sort(
            key=lambda candidate_index: line_similarity_sort_key(
                target, lines[candidate_index]
            )
        )
        result.append(candidates[:maximum])
    return result


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_fixed_artifact(path: Path, expected_size: int, expected_sha: str) -> None:
    actual_size = path.stat().st_size
    actual_sha = sha256_file(path)
    if (actual_size, actual_sha) != (expected_size, expected_sha):
        raise GenerationError(
            f"{repo_relative(path)} is not the pinned artifact: "
            f"size={actual_size}, sha256={actual_sha}"
        )


def validate_quran_source(payload: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    surahs = payload.get("surahs")
    ayahs = payload.get("ayahs")
    if not isinstance(surahs, list) or not isinstance(ayahs, list):
        raise GenerationError("quran_reader.json must contain surahs and ayahs arrays")
    if len(surahs) != EXPECTED_SURAH_COUNT or len(ayahs) != EXPECTED_AYAH_COUNT:
        raise GenerationError(
            f"expected {EXPECTED_SURAH_COUNT} surahs/{EXPECTED_AYAH_COUNT} ayahs; "
            f"found {len(surahs)} surahs/{len(ayahs)} ayahs"
        )

    ordered_surahs = sorted(surahs, key=lambda value: int(value["number"]))
    if [int(value["number"]) for value in ordered_surahs] != list(range(1, 115)):
        raise GenerationError("surah numbers are not exactly 1...114")

    ordered_ayahs = sorted(
        ayahs, key=lambda value: (int(value["surah"]), int(value["ayah"]))
    )
    seen: set[tuple[int, int]] = set()
    by_surah: dict[int, list[int]] = {}
    for ayah in ordered_ayahs:
        key = (int(ayah["surah"]), int(ayah["ayah"]))
        if key in seen:
            raise GenerationError(f"duplicate ayah {key[0]}:{key[1]}")
        seen.add(key)
        by_surah.setdefault(key[0], []).append(key[1])
        if not isinstance(ayah.get("arabic"), str) or not ayah["arabic"].strip():
            raise GenerationError(f"ayah {key[0]}:{key[1]} has no Arabic source text")

    for surah in ordered_surahs:
        number = int(surah["number"])
        expected_count = int(surah["ayah_count"])
        if by_surah.get(number) != list(range(1, expected_count + 1)):
            raise GenerationError(f"surah {number} ayah sequence/count mismatch")
    return ordered_surahs, ordered_ayahs


def numbered_ayah_text(ayah: dict[str, Any], headers: dict[int, str]) -> str:
    """Same source-preserving preamble separation as QuranReaderData.decode.

    Tanzil's 95/97 first beh has shadda: compare letters, not vocalization.
    Slice the original source; never rewrite or normalize the displayed verse.
    """
    source = ayah["arabic"]
    number = int(ayah["surah"])
    if int(ayah["ayah"]) != 1 or number in (1, 9):
        return source
    prefix = headers.get(number, "").split()
    words = list(re.finditer(r"\S+", source))
    def letters(word: str) -> str:
        return "".join(c for c in word if unicodedata.category(c) == "Lo" and c != "ـ")
    if len(prefix) == 4 and len(words) > 4 and all(
        letters(a) == letters(b.group()) for a, b in zip(prefix, words)
    ):
        return source[words[4].start():]
    return source


def validate_tokenizer_vocabulary(
    processor: Any, vocabulary_payload: dict[str, str]
) -> None:
    if processor.vocab_size() != 1024 or processor.unk_id() != 0:
        raise GenerationError(
            f"unexpected tokenizer shape: vocab={processor.vocab_size()}, "
            f"unk={processor.unk_id()}"
        )
    if len(vocabulary_payload) != 1025 or vocabulary_payload.get("1024") != "<blank>":
        raise GenerationError("vocab.json must contain 1,024 pieces plus CTC blank 1,024")
    for token_id in range(processor.vocab_size()):
        expected = processor.id_to_piece(token_id)
        if vocabulary_payload.get(str(token_id)) != expected:
            raise GenerationError(
                f"vocab/tokenizer mismatch at token {token_id}: "
                f"{vocabulary_payload.get(str(token_id))!r} != {expected!r}"
            )


def encode_words(processor: Any, words: list[str], reference: str) -> tuple[list[int], list[int]]:
    token_ids, word_token_ends = cumulative_ends(
        processor.encode(word, out_type=int) for word in words
    )
    full_encoding = processor.encode(" ".join(words), out_type=int)
    if token_ids != full_encoding:
        raise GenerationError(
            f"per-word and full-text SentencePiece encodings differ at {reference}"
        )
    if processor.unk_id() in token_ids:
        raise GenerationError(f"pinned tokenizer emits <unk> at {reference}")
    return token_ids, word_token_ends


def write_atomically(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        path.chmod(0o644)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass

def build_outputs():
    if spm.__version__ != EXPECTED_SENTENCEPIECE_VERSION:
        raise GenerationError('Install the pinned Tools/requirements.txt')
    validate_fixed_artifact(TOKENIZER_PATH, EXPECTED_TOKENIZER_SIZE, EXPECTED_TOKENIZER_SHA256)
    validate_fixed_artifact(VOCAB_PATH, EXPECTED_VOCAB_SIZE, EXPECTED_VOCAB_SHA256)
    q=load_json(QURAN_PATH)
    surahs, ayahs=validate_quran_source(q)
    processor=spm.SentencePieceProcessor(model_file=str(TOKENIZER_PATH))
    validate_tokenizer_vocabulary(processor,load_json(VOCAB_PATH))
    headers={int(s['number']):s['bismillah'] for s in surahs}
    records=[]; arabic=[]
    for a in ayahs:
        text=numbered_ayah_text(a,headers)
        words=[normalize_arabic(w.source) for w in semantic_words(text)]
        tokens,ends=encode_words(processor,words,f"{a['surah']}:{a['ayah']}")
        records.append([a['surah'],a['ayah'],words,tokens,ends,[len(words)]])
        arabic.append(text)
    confusers=build_line_confusers(records)
    policy={'version':1,'maximum_per_line':16,'canonical_line_order':'ayah record order, then segment_word_ends order within each ayah','excluded_implicit_runtime_confusers':['same-ayah sibling lines','canonical global line index +/-2']}
    payload={'attribution':q['attribution'],'schema_version':2,'record_layout':['surah','ayah','normalized_words','token_ids','word_token_ends','segment_word_ends'],'ayahs':records,'arabic':arabic,'surahs':surahs,'line_confuser_policy':policy,'line_confusers':confusers,'normalization':{'id':'quran-arabic-v1','implementation':'ArabicNormalizer.swift'},'statistics':{'ayah_count':len(records),'surah_count':len(surahs),'semantic_word_count':sum(len(r[2]) for r in records),'segment_count':len(records),'line_confuser_count':sum(map(len,confusers))}}
    data=canonical_json(payload)
    manifest={'schema_version':2,'artifacts':{'quran_token_map':{'file':'quran-token-map.json','sha256':sha256_bytes(data),'size':len(data)}},'generator':{'file':'Tools/generate_token_map.py','sha256':sha256_file(Path(__file__))},'source':{'file':'Tools/data/quran-uthmani.json','sha256':sha256_file(QURAN_PATH),'attribution':q['attribution']},'tokenizer':{'sha256':EXPECTED_TOKENIZER_SHA256,'sentencepiece_version':spm.__version__},'vocabulary':{'sha256':EXPECTED_VOCAB_SHA256}}
    return {'quran-token-map.json':data,'quran-token-map.manifest.json':canonical_json(manifest)}

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    outputs=build_outputs()
    for name,data in outputs.items():
        path=OUTPUT/name
        if args.check:
            if not path.exists() or path.read_bytes()!=data: raise GenerationError(f'Stale resource: {name}')
        else: write_atomically(path,data)
    print('Token map verified: 114 surahs, 6236 ayahs; SHA256 '+sha256_bytes(outputs['quran-token-map.json']))
if __name__=='__main__': main()
