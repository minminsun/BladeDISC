// Copyright 2022 The BladeDISC Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include <torch/csrc/lazy/ts_backend/ts_node.h>

namespace torch {
namespace lazy {

class TORCH_API Permute : public TsNode {
 public:
  static OpKind ClassOpKind() {
    return OpKind(at::aten::permute);
  }

  Permute(const Value& input, std::vector<int64_t> dims);

  std::string ToString() const override;

  const std::vector<int64_t>& dims() const {
    return dims_;
  }

 private:
  // The permutation of dimensions.
  std::vector<int64_t> dims_;
};

} // namespace lazy
} // namespace torch
