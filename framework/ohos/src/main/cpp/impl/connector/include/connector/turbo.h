/*
 *
 * Tencent is pleased to support the open source community by making
 * Hippy available.
 *
 * Copyright (C) 2019 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#pragma once

#include "oh_napi/ark_ts.h"

namespace hippy {
inline namespace framework {
inline namespace turbo {

void InitTurbo(napi_env env);

class Turbo {
 public:
  Turbo(napi_ref ref) : ref_(ref) {}

  inline napi_ref GetRef() {
    return ref_;
  }
 private:
  napi_ref ref_;
};

}
}
}
