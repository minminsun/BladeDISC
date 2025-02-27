# Copyright 2022 The BladeDISC Authors. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import unittest
from typing import Any, Dict, List

import numpy as np
from blade_adapter import pipeline
from parameterized import parameterized
from transformers import DistilBertForSequenceClassification
from transformers import pipeline as hf_pipeline


class PipelineTest(unittest.TestCase):
    def test_task_default(self) -> None:
        pipe = pipeline(task="text-classification")
        output = pipe("This restaurant is awesome")
        self.assertTrue(output)
        self.assertEqual(output[0]['label'], 'POSITIVE')
        self.assertGreater(output[0]['score'], 0.9)

    def test_task_model_id(self) -> None:
        pipe = pipeline(
            model="distilbert-base-uncased-finetuned-sst-2-english")
        output = pipe("This restaurant is awesome")
        self.assertTrue(output)
        self.assertEqual(output[0]['label'], 'POSITIVE')
        self.assertGreater(output[0]['score'], 0.9)

    def test_preloaded_model(self) -> None:
        model = DistilBertForSequenceClassification.from_pretrained(
            'distilbert-base-uncased-finetuned-sst-2-english', torchscript=True)
        pipe = pipeline(task="text-classification", model=model)
        output = pipe("This restaurant is awesome")
        self.assertTrue(output)
        self.assertEqual(output[0]['label'], 'POSITIVE')
        self.assertGreater(output[0]['score'], 0.9)

    @parameterized.expand([
        ("feature-extraction", ["hello world."], {}),
        ("text-classification", ["This restaurant is awesome"], {}),
        ("token-classification", ["What's the weather in Shanghai?"], {}),
        ("question-answering", [], {
            "context": "Alice is the CEO. Bob is sitting next to her.",
            "question": "Who is sitting next to CEO?",
        }),
        ("fill-mask", ["The man worked as a <mask>."], {}),
        # TODO(litan.ls): support seq2seq-lm tasks
        # ("summarization", [r'''The tower is 324 metres (1,063 ft) tall,
        #    about the same height as an 81-storey building,
        #    and the tallest structure in Paris.'''], {}),
        # ("translation_en_to_fr", ["Hello!"], {}),
    ])
    def test_task_coverage(self, task: str, input_args: List[Any],
                           input_kwargs: Dict[str, Any]) -> None:
        pipe = pipeline(task=task, skip_compile=True)
        # skip compilation for fast functionality test
        output = pipe(*input_args, **input_kwargs)
        hf_pipe = hf_pipeline(task=task)
        hf_output = hf_pipe(*input_args, **input_kwargs)

        def _compare(a, b):
            self.assertEqual(type(a), type(b))
            if np.asarray(a).dtype.kind == 'f':
                np.testing.assert_allclose(a, b, rtol=0.01, atol=0.01)
            elif isinstance(a, dict):
                self.assertEqual(a.keys(), b.keys())
                for x in a:
                    _compare(a[x], b[x])
            elif isinstance(a, list):
                self.assertEqual(len(a), len(b))
                for x, y in zip(a, b):
                    _compare(x, y)
            else:
                self.assertEqual(a, b)

        _compare(output, hf_output)


if __name__ == '__main__':
    unittest.main()
