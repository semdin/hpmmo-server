// Password hashing (argon2id) and credential-string helpers.
#pragma once

#include "config.h"

#include <string>

namespace auth {

// Returns a PHC-format argon2id string: $argon2id$v=19$m=...,t=...,p=...$salt$hash
std::string hash_password(const std::string& password, const Config& cfg);

// Constant-time verification of a password against a stored PHC string.
bool verify_password(const std::string& password, const std::string& stored_phc);

// Constant-time equality for tokens (service token comparisons).
bool constant_time_equal(const std::string& a, const std::string& b);

struct PasswordPolicy {
    bool ok = false;
    std::string message;
};

PasswordPolicy check_password_policy(const std::string& password);
PasswordPolicy check_username_policy(const std::string& username);

}  // namespace auth
