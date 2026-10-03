#include "auth.h"

#include "db.h"

#include <argon2.h>

#include <cctype>
#include <cstring>
#include <vector>

namespace auth {

std::string hash_password(const std::string& password, const Config& cfg) {
    constexpr size_t kSaltLen = 16;
    constexpr size_t kHashLen = 32;
    unsigned char salt[kSaltLen];
    db::secure_random_bytes(salt, kSaltLen);  // per-password salt from the OS CSPRNG
    std::vector<char> encoded(argon2_encodedlen(cfg.argon2_t_cost, cfg.argon2_m_cost,
                                                cfg.argon2_parallelism, kSaltLen, kHashLen,
                                                Argon2_id));
    if (argon2id_hash_encoded(cfg.argon2_t_cost, cfg.argon2_m_cost, cfg.argon2_parallelism,
                              password.data(), password.size(), salt, kSaltLen, kHashLen,
                              encoded.data(), encoded.size()) != ARGON2_OK) {
        return "";
    }
    return std::string(encoded.data());
}

bool verify_password(const std::string& password, const std::string& stored_phc) {
    if (stored_phc.empty()) return false;
    return argon2id_verify(stored_phc.c_str(), password.data(), password.size()) == ARGON2_OK;
}

bool constant_time_equal(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        diff |= static_cast<unsigned char>(a[i] ^ b[i]);
    }
    return diff == 0;
}

PasswordPolicy check_password_policy(const std::string& password) {
    if (password.size() < 8) return {false, "Password must be at least 8 characters."};
    if (password.size() > 128) return {false, "Password is too long (max 128)."};
    bool has_letter = false;
    bool has_digit = false;
    for (const char c : password) {
        if (std::isalpha(static_cast<unsigned char>(c))) has_letter = true;
        if (std::isdigit(static_cast<unsigned char>(c))) has_digit = true;
    }
    if (!has_letter || !has_digit) return {false, "Password must contain letters and digits."};
    return {true, ""};
}

PasswordPolicy check_username_policy(const std::string& username) {
    if (username.size() < 3 || username.size() > 24) return {false, "Username must be 3-24 characters."};
    for (const char c : username) {
        if (!std::isalnum(static_cast<unsigned char>(c)) && c != '_' && c != '-') {
            return {false, "Username may contain only letters, digits, '_' and '-'."};
        }
    }
    return {true, ""};
}

}  // namespace auth
