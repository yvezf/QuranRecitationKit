#!/usr/bin/env python3
"""Convert NVIDIA SentencePiece Unigram pieces/scores to Hugging Face tokenizer JSON.

No corpus index is written. Verify token parity locally with QRK_PARITY_TOKEN_MAP.
Requires sentencepiece==0.2.1, tokenizers==0.22.2. Output is NVIDIA tokenizer data.
"""
from pathlib import Path
import hashlib, json
import sentencepiece as spm
from tokenizers import Tokenizer, models, pre_tokenizers, decoders, normalizers
ROOT=Path(__file__).resolve().parent
source=ROOT/'tokenizer.model'
assert hashlib.sha256(source.read_bytes()).hexdigest()=='1fcfa104fa448c979cc2537788947c6516827f403ecdc55c4895b77d28630ba4'
sp=spm.SentencePieceProcessor(model_file=str(source))
vocab={sp.id_to_piece(i):i for i in range(sp.vocab_size())}
# Scores in this NVIDIA model are unigram log probabilities, not BPE merge ranks.
# Preserve the model's actual inference algorithm rather than guessing from its name.
t=Tokenizer(models.Unigram([(sp.id_to_piece(i),sp.get_score(i)) for i in range(sp.vocab_size())],unk_id=sp.unk_id(),byte_fallback=False))
t.normalizer=normalizers.NFKC()
t.pre_tokenizer=pre_tokenizers.Metaspace(replacement='▁',prepend_scheme='always',split=True)
t.decoder=decoders.Metaspace(replacement='▁',prepend_scheme='always')
t.save(str(ROOT/'tokenizer.json'))
# Comparison is in memory only; no normalized Quran data is serialized.
q=json.loads((ROOT.parent/'corpus/quran-uthmani.json').read_text())
import importlib.util
script=ROOT.parent/'tests/dev/generate_swift_token_map.py'
spec=importlib.util.spec_from_file_location('dev_index',script);module=importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name]=module;spec.loader.exec_module(module)
words=[]
for ayah in q['ayahs']:
    words.extend(module.normalize_arabic(w.source) for w in module.semantic_words(ayah['arabic']))
errors=[]
for word in set(words):
    if t.encode(word).ids != sp.encode(word,out_type=int): errors.append((word,t.encode(word).ids,sp.encode(word,out_type=int)))
if errors: raise RuntimeError(f'{len(errors)} tokenization mismatches; first: {errors[:5]}')
meta={'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'json_sha256':hashlib.sha256((ROOT/'tokenizer.json').read_bytes()).hexdigest(),'sentencepiece':'0.2.1','tokenizers':'0.22.2','verified_word_count':len(words),'unique_word_count':len(set(words))}
(ROOT/'tokenizer-conversion.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta))
