# Recording-free continuous event receipt — 0.2.1

```json
{
  "sdk": "0.2.1",
  "source": "owned local recording; audio and raw transcript not distributed",
  "input_seconds": 10.798,
  "default_model": "model-v2",
  "models": {
    "model-v2": {
      "passed": true,
      "cases": [
        {
          "case": "range_78_1_2",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 1.2,
              "event": {
                "ayah": 1,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 2.7,
              "event": {
                "ayah": 1,
                "confidence": 0.4536941892992596,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 5.7,
              "event": {
                "ayah": 1,
                "confidence": 0.6651591835003529,
                "duration_seconds": 4.5125,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.5,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.8,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 9.3,
              "event": {
                "ayah": 2,
                "confidence": 0.43380257526326577,
                "matched_word_indices": [
                  0,
                  1,
                  2
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 2
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.5422445976334517,
                "duration_seconds": 4.538625,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6651591835003529,
              "duration_seconds": 4.5125,
              "surah": 78
            },
            {
              "ayah": 2,
              "confidence": 0.5422445976334517,
              "duration_seconds": 4.538625,
              "surah": 78
            }
          ]
        },
        {
          "case": "selected_78_1_1_continuing",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 1.2,
              "event": {
                "ayah": 1,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 2.7,
              "event": {
                "ayah": 1,
                "confidence": 0.4536941892992596,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 5.7,
              "event": {
                "ayah": 1,
                "confidence": 0.6651591835003529,
                "duration_seconds": 4.5125,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6651591835003529,
              "duration_seconds": 4.5125,
              "surah": 78
            }
          ]
        },
        {
          "case": "whole_surah_78_partial",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 1.2,
              "event": {
                "ayah": 1,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 2.7,
              "event": {
                "ayah": 1,
                "confidence": 0.4536941892992596,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 5.7,
              "event": {
                "ayah": 1,
                "confidence": 0.6651591835003529,
                "duration_seconds": 4.5125,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.5,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.8,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 9.3,
              "event": {
                "ayah": 2,
                "confidence": 0.43380257526326577,
                "matched_word_indices": [
                  0,
                  1,
                  2
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 2
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.5422445976334517,
                "duration_seconds": 4.538625,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 3,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 4,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "reason": "off_target",
                "type": "needs_retry"
              },
              "phase": "stop"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6651591835003529,
              "duration_seconds": 4.5125,
              "surah": 78
            },
            {
              "ayah": 2,
              "confidence": 0.5422445976334517,
              "duration_seconds": 4.538625,
              "surah": 78
            }
          ]
        },
        {
          "case": "terminal_range_78_1_2",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 1,
                "confidence": 0.6424043080320614,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 1,
                "confidence": 0.6424043080320614,
                "duration_seconds": 4.452375,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.517960623214129,
                "matched_word_indices": [
                  0,
                  1,
                  2
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 2
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.517960623214129,
                "duration_seconds": 4.611375,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "stop"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6424043080320614,
              "duration_seconds": 4.452375,
              "surah": 78
            },
            {
              "ayah": 2,
              "confidence": 0.517960623214129,
              "duration_seconds": 4.611375,
              "surah": 78
            }
          ]
        },
        {
          "case": "wrong_target_surah_1",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 10.798,
              "event": {
                "reason": "off_target",
                "type": "needs_retry"
              },
              "phase": "stop"
            }
          ],
          "verses": []
        }
      ]
    },
    "model-v1": {
      "passed": true,
      "cases": [
        {
          "case": "range_78_1_2",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 1.2,
              "event": {
                "ayah": 1,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 2.7,
              "event": {
                "ayah": 1,
                "confidence": 0.35227878282536873,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 5.7,
              "event": {
                "ayah": 1,
                "confidence": 0.6628081476600942,
                "duration_seconds": 4.5125,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.5,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.8,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 9.3,
              "event": {
                "ayah": 2,
                "confidence": 0.4566596324478937,
                "matched_word_indices": [
                  0,
                  1,
                  2
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 2
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.5105147823744379,
                "duration_seconds": 4.538625,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6628081476600942,
              "duration_seconds": 4.5125,
              "surah": 78
            },
            {
              "ayah": 2,
              "confidence": 0.5105147823744379,
              "duration_seconds": 4.538625,
              "surah": 78
            }
          ]
        },
        {
          "case": "selected_78_1_1_continuing",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 1.2,
              "event": {
                "ayah": 1,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 2.7,
              "event": {
                "ayah": 1,
                "confidence": 0.35227878282536873,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 5.7,
              "event": {
                "ayah": 1,
                "confidence": 0.6628081476600942,
                "duration_seconds": 4.5125,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6628081476600942,
              "duration_seconds": 4.5125,
              "surah": 78
            }
          ]
        },
        {
          "case": "whole_surah_78_partial",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 1.2,
              "event": {
                "ayah": 1,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 2.7,
              "event": {
                "ayah": 1,
                "confidence": 0.35227878282536873,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 5.7,
              "event": {
                "ayah": 1,
                "confidence": 0.6628081476600942,
                "duration_seconds": 4.5125,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.5,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 7.8,
              "event": {
                "ayah": 2,
                "confidence": 0.0,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 9.3,
              "event": {
                "ayah": 2,
                "confidence": 0.4566596324478937,
                "matched_word_indices": [
                  0,
                  1,
                  2
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 2
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.5105147823744379,
                "duration_seconds": 4.538625,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "feed"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 3,
                "confidence": 0.0,
                "matched_word_indices": [
                  0
                ],
                "surah": 78,
                "total_words": 4,
                "type": "word_progress",
                "word_index": 0
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "reason": "off_target",
                "type": "needs_retry"
              },
              "phase": "stop"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6628081476600942,
              "duration_seconds": 4.5125,
              "surah": 78
            },
            {
              "ayah": 2,
              "confidence": 0.5105147823744379,
              "duration_seconds": 4.538625,
              "surah": 78
            }
          ]
        },
        {
          "case": "terminal_range_78_1_2",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 1,
                "confidence": 0.6221178033099286,
                "matched_word_indices": [
                  0,
                  1
                ],
                "surah": 78,
                "total_words": 2,
                "type": "word_progress",
                "word_index": 1
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 1,
                "confidence": 0.6221178033099286,
                "duration_seconds": 4.452375,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.5143913859230377,
                "matched_word_indices": [
                  0,
                  1,
                  2
                ],
                "surah": 78,
                "total_words": 3,
                "type": "word_progress",
                "word_index": 2
              },
              "phase": "stop"
            },
            {
              "audio_seconds": 10.798,
              "event": {
                "ayah": 2,
                "confidence": 0.5143913859230377,
                "duration_seconds": 4.611375,
                "surah": 78,
                "type": "verse_match"
              },
              "phase": "stop"
            }
          ],
          "verses": [
            {
              "ayah": 1,
              "confidence": 0.6221178033099286,
              "duration_seconds": 4.452375,
              "surah": 78
            },
            {
              "ayah": 2,
              "confidence": 0.5143913859230377,
              "duration_seconds": 4.611375,
              "surah": 78
            }
          ]
        },
        {
          "case": "wrong_target_surah_1",
          "passed": true,
          "raw_confidence_valid": true,
          "events": [
            {
              "audio_seconds": 10.798,
              "event": {
                "reason": "off_target",
                "type": "needs_retry"
              },
              "phase": "stop"
            }
          ],
          "verses": []
        }
      ]
    }
  },
  "resampling": {
    "passed": true,
    "mean_downmix": "duplicated stereo has bit-identical mono PCM; matching confidence within 1e-6",
    "cases": [
      {
        "case": "mono48",
        "confidence": 0.6825031710161402,
        "surah": 78,
        "ayah": 1,
        "exit_code": 0
      },
      {
        "case": "duplicated_stereo48",
        "confidence": 0.6825031710161402,
        "surah": 78,
        "ayah": 1,
        "exit_code": 0
      },
      {
        "case": "mono44",
        "confidence": 0.6814622716347675,
        "surah": 78,
        "ayah": 1,
        "exit_code": 0
      }
    ]
  }
}
```

## Downloaded CLI target boundaries

```json
{
  "sdk": "0.2.1",
  "cases": [
    {
      "case": "selected_78_1_continuing",
      "exit": 0,
      "verses": [
        [
          78,
          1
        ]
      ],
      "retries": [],
      "passed": true
    },
    {
      "case": "wrong_target",
      "exit": 1,
      "verses": [],
      "retries": [
        "off_target"
      ],
      "passed": true
    }
  ],
  "passed": true
}
```
