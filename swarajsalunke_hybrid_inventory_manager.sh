#!/bin/bash
# =============================================================================
# Hybrid Inventory Manager - Self-Extracting Project Archive
# Run: bash hybrid_inventory_manager.sh
# This will create the full project in ./HybridInventoryManager/
# =============================================================================

set -e

PROJECT_DIR="HybridInventoryManager"
mkdir -p "$PROJECT_DIR/include"
mkdir -p "$PROJECT_DIR/src"

echo ">>> Creating project structure..."

# =============================================================================
# FILE 1: include/inventory.h
# =============================================================================
cat > "$PROJECT_DIR/include/inventory.h" << 'HEADER_EOF'
/*
 * inventory.h
 * -----------
 * C backend interface for the Hybrid Inventory Manager.
 * Defines the core Item struct and the strict C API used by the C++ layer.
 *
 * Architecture rule: This header is shared between C and C++ translation
 * units. All declarations are wrapped in extern "C" guards so g++ can link
 * against the C-compiled object without name-mangling issues.
 */

#ifndef INVENTORY_H
#define INVENTORY_H

/* ── Constants ─────────────────────────────────────────────────────────── */
#define INVENTORY_FILE  "inventory.dat"
#define NAME_MAX_LEN    40
#define MAX_ITEMS       1024   /* hard upper bound for list_items buffer   */

/* ── Core data structure (plain C struct, binary-compatible) ────────────── */
typedef struct {
    int   id;                   /* must be > 0 and unique                  */
    char  name[NAME_MAX_LEN];   /* null-terminated, must not be empty      */
    int   quantity;             /* must be >= 0                            */
    float price;                /* must be >= 0.0f                         */
    int   is_deleted;           /* soft-delete flag: 1 = deleted, 0 = live */
} Item;

/* ── C Backend API ──────────────────────────────────────────────────────── */
/*
 * All functions return 1 on success, 0 on failure.
 * list_items() is the exception: it returns the count of valid items found
 * (0 means none found, which is not an error per se).
 *
 * The C layer performs NO user I/O. It is a pure data-access layer.
 */

#ifdef __cplusplus
extern "C" {
#endif

/*
 * add_item()
 *   Appends a new item record to inventory.dat.
 *   Fails if: id <= 0, id already exists (live record), name is empty,
 *             quantity < 0, price < 0, or file I/O error.
 */
int add_item(const Item* item);

/*
 * get_item()
 *   Searches inventory.dat for a live record matching `id`.
 *   On success, copies the record into *out and returns 1.
 *   Returns 0 if not found or soft-deleted.
 */
int get_item(int id, Item* out);

/*
 * update_item()
 *   Performs an in-place update of the record with matching `id`.
 *   Uses fseek to overwrite only the affected record.
 *   Validates the updated struct before writing.
 *   Returns 0 if id not found, soft-deleted, or validation fails.
 */
int update_item(int id, const Item* updated);

/*
 * delete_item()
 *   Soft-deletes the record by setting is_deleted = 1 in-place.
 *   Returns 0 if id not found or already deleted.
 */
int delete_item(int id);

/*
 * list_items()
 *   Reads all non-deleted records into `buffer` (up to max_items entries).
 *   Returns the number of valid records copied.
 *   Caller must provide a buffer large enough (use MAX_ITEMS to be safe).
 */
int list_items(Item* buffer, int max_items);

#ifdef __cplusplus
}
#endif

#endif /* INVENTORY_H */
HEADER_EOF

echo "  [OK] include/inventory.h"

# =============================================================================
# FILE 2: src/inventory.c
# =============================================================================
cat > "$PROJECT_DIR/src/inventory.c" << 'C_EOF'
/*
 * inventory.c
 * -----------
 * C backend implementation for the Hybrid Inventory Manager.
 *
 * Design principles:
 *  - Binary file I/O via fopen/fread/fwrite/fseek (no fprintf for data).
 *  - Every record occupies exactly sizeof(Item) bytes; random access by index.
 *  - Soft delete: is_deleted flag is toggled; no records are ever physically
 *    removed, preserving file offsets for other records.
 *  - No dynamic memory allocation in this layer (caller supplies buffers).
 *  - No C++ headers, features, or idioms.
 */

#include "inventory.h"

#include <stdio.h>
#include <string.h>

/* ── Internal helpers ───────────────────────────────────────────────────── */

/*
 * validate_item()
 *   Returns 1 if the item fields satisfy business rules, 0 otherwise.
 *   Called before every write operation.
 */
static int validate_item(const Item* item)
{
    if (!item)                          return 0;
    if (item->id <= 0)                  return 0;
    if (item->name[0] == '\0')          return 0;
    if (item->quantity < 0)             return 0;
    if (item->price < 0.0f)             return 0;
    return 1;
}

/*
 * open_file()
 *   Opens INVENTORY_FILE with the given mode.
 *   "rb+" requires the file to exist; callers that need creation use "ab".
 *   Returns NULL on failure.
 */
static FILE* open_file(const char* mode)
{
    return fopen(INVENTORY_FILE, mode);
}

/*
 * count_records()
 *   Returns the total number of records (including deleted) in the file,
 *   or -1 on error. Used to determine file size / last record index.
 */
static long count_records(FILE* fp)
{
    if (fseek(fp, 0L, SEEK_END) != 0) return -1;
    long size = ftell(fp);
    if (size < 0) return -1;
    return size / (long)sizeof(Item);
}

/*
 * id_exists()
 *   Scans all records for a live (non-deleted) entry with matching id.
 *   Returns the 0-based record index if found, or -1 if not found.
 *   fp must be open for reading.
 */
static long id_exists(FILE* fp, int id)
{
    long total = count_records(fp);
    if (total <= 0) return -1;

    Item tmp;
    for (long i = 0; i < total; i++) {
        if (fseek(fp, i * (long)sizeof(Item), SEEK_SET) != 0) continue;
        if (fread(&tmp, sizeof(Item), 1, fp) != 1)            continue;
        if (tmp.id == id && !tmp.is_deleted)                  return i;
    }
    return -1;
}

/* ── Public API implementation ─────────────────────────────────────────── */

int add_item(const Item* item)
{
    if (!validate_item(item)) return 0;

    /* ── Duplicate-ID check ── */
    FILE* fp = open_file("rb");        /* open for read; may not exist yet  */
    if (fp) {
        long idx = id_exists(fp, item->id);
        fclose(fp);
        if (idx >= 0) return 0;       /* duplicate found → reject           */
    }

    /* ── Append new record ── */
    fp = open_file("ab");             /* create or append in binary mode    */
    if (!fp) return 0;

    /* Ensure name is null-terminated (defensive copy) */
    Item safe = *item;
    safe.name[NAME_MAX_LEN - 1] = '\0';
    safe.is_deleted = 0;

    int ok = (fwrite(&safe, sizeof(Item), 1, fp) == 1);
    fclose(fp);
    return ok;
}

int get_item(int id, Item* out)
{
    if (id <= 0 || !out) return 0;

    FILE* fp = open_file("rb");
    if (!fp) return 0;

    long idx = id_exists(fp, id);
    if (idx < 0) { fclose(fp); return 0; }

    /* Seek back to the found position and read into *out */
    int ok = 0;
    if (fseek(fp, idx * (long)sizeof(Item), SEEK_SET) == 0)
        ok = (fread(out, sizeof(Item), 1, fp) == 1);

    fclose(fp);
    return ok;
}

int update_item(int id, const Item* updated)
{
    if (id <= 0 || !updated)          return 0;
    if (!validate_item(updated))      return 0;
    if (updated->id != id)            return 0; /* id must not change       */

    FILE* fp = open_file("rb+");      /* open for read+write; must exist    */
    if (!fp) return 0;

    long idx = id_exists(fp, id);
    if (idx < 0) { fclose(fp); return 0; }

    /* In-place overwrite at exact file offset */
    int ok = 0;
    if (fseek(fp, idx * (long)sizeof(Item), SEEK_SET) == 0) {
        Item safe = *updated;
        safe.name[NAME_MAX_LEN - 1] = '\0';
        safe.is_deleted = 0;
        ok = (fwrite(&safe, sizeof(Item), 1, fp) == 1);
        fflush(fp);
    }

    fclose(fp);
    return ok;
}

int delete_item(int id)
{
    if (id <= 0) return 0;

    FILE* fp = open_file("rb+");
    if (!fp) return 0;

    long idx = id_exists(fp, id);
    if (idx < 0) { fclose(fp); return 0; }

    /* Read the record, flip the flag, write it back in-place */
    int ok = 0;
    if (fseek(fp, idx * (long)sizeof(Item), SEEK_SET) == 0) {
        Item tmp;
        if (fread(&tmp, sizeof(Item), 1, fp) == 1) {
            tmp.is_deleted = 1;
            /* Seek back: fread advanced the pointer by sizeof(Item) */
            if (fseek(fp, idx * (long)sizeof(Item), SEEK_SET) == 0) {
                ok = (fwrite(&tmp, sizeof(Item), 1, fp) == 1);
                fflush(fp);
            }
        }
    }

    fclose(fp);
    return ok;
}

int list_items(Item* buffer, int max_items)
{
    if (!buffer || max_items <= 0) return 0;

    FILE* fp = open_file("rb");
    if (!fp) return 0;           /* no file yet → 0 items (not an error)   */

    long total = count_records(fp);
    if (total <= 0) { fclose(fp); return 0; }

    rewind(fp);
    int count = 0;
    Item tmp;

    for (long i = 0; i < total && count < max_items; i++) {
        if (fread(&tmp, sizeof(Item), 1, fp) != 1) break;
        if (!tmp.is_deleted)
            buffer[count++] = tmp;
    }

    fclose(fp);
    return count;
}
C_EOF

echo "  [OK] src/inventory.c"

# =============================================================================
# FILE 3: src/InventoryManager.cpp
# =============================================================================
cat > "$PROJECT_DIR/src/InventoryManager.cpp" << 'CPP_EOF'
/*
 * InventoryManager.cpp
 * --------------------
 * C++ frontend layer for the Hybrid Inventory Manager.
 *
 * This class is responsible for:
 *   - All terminal I/O (menus, prompts, formatted tables)
 *   - Input validation and sanitization (preventing crashes)
 *   - Calling the C backend API (via extern "C" linkage)
 *   - STL usage: std::vector<Item> for buffering, std::sort for ordering
 *
 * Architecture rule: No file I/O is performed here. All persistence is
 * delegated exclusively to the C backend functions in inventory.c.
 */

#include "InventoryManager.h"
#include "inventory.h"

#include <iostream>
#include <iomanip>
#include <sstream>
#include <algorithm>
#include <limits>
#include <cctype>
#include <cstring>
#include <vector>

/* ── ANSI colour helpers (gracefully degrade on non-ANSI terminals) ─────── */
namespace Color {
    const char* RESET  = "\033[0m";
    const char* BOLD   = "\033[1m";
    const char* CYAN   = "\033[36m";
    const char* GREEN  = "\033[32m";
    const char* YELLOW = "\033[33m";
    const char* RED    = "\033[31m";
    const char* WHITE  = "\033[37m";
    const char* DIM    = "\033[2m";
}

/* ── Internal formatting constants ──────────────────────────────────────── */
static const int COL_ID    =  6;
static const int COL_NAME  = 22;
static const int COL_QTY   =  9;
static const int COL_PRICE = 12;

/* ═══════════════════════════════════════════════════════════════════════════
 * Input helpers
 * ═══════════════════════════════════════════════════════════════════════════ */

/*
 * clearInputBuffer()
 *   Flushes any stale characters left in stdin after a failed extraction.
 *   Prevents infinite loops and skipped prompts.
 */
static void clearInputBuffer()
{
    std::cin.clear();
    std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
}

/*
 * readInt()
 *   Prompts the user and reads a validated integer.
 *   Loops until the user provides a syntactically valid integer.
 */
static int readInt(const std::string& prompt)
{
    int value;
    while (true) {
        std::cout << prompt;
        if (std::cin >> value) {
            clearInputBuffer();
            return value;
        }
        std::cerr << Color::RED << "  [!] Invalid input. Please enter a whole number.\n"
                  << Color::RESET;
        clearInputBuffer();
    }
}

/*
 * readFloat()
 *   Same contract as readInt() but for floating-point values.
 */
static float readFloat(const std::string& prompt)
{
    float value;
    while (true) {
        std::cout << prompt;
        if (std::cin >> value) {
            clearInputBuffer();
            return value;
        }
        std::cerr << Color::RED << "  [!] Invalid input. Please enter a number (e.g. 9.99).\n"
                  << Color::RESET;
        clearInputBuffer();
    }
}

/*
 * readString()
 *   Reads a line of text. Strips leading/trailing whitespace.
 *   Loops until the result is non-empty.
 */
static std::string readString(const std::string& prompt)
{
    std::string value;
    while (true) {
        std::cout << prompt;
        std::getline(std::cin, value);

        /* Strip leading whitespace */
        size_t start = value.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) { value.clear(); }
        else {
            size_t end = value.find_last_not_of(" \t\r\n");
            value = value.substr(start, end - start + 1);
        }

        if (!value.empty()) return value;
        std::cerr << Color::RED << "  [!] Name cannot be empty.\n" << Color::RESET;
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * InventoryManager – constructor / destructor
 * ═══════════════════════════════════════════════════════════════════════════ */

InventoryManager::InventoryManager()
{
    /* Nothing to initialize: state lives in inventory.dat, not in RAM. */
}

InventoryManager::~InventoryManager()
{
    /* No heap allocations to free. */
}

/* ═══════════════════════════════════════════════════════════════════════════
 * UI helpers
 * ═══════════════════════════════════════════════════════════════════════════ */

void InventoryManager::printBanner() const
{
    std::cout << Color::CYAN << Color::BOLD;
    std::cout << "\n";
    std::cout << "  ╔══════════════════════════════════════╗\n";
    std::cout << "  ║     HYBRID INVENTORY MANAGER  v1.0   ║\n";
    std::cout << "  ║      Backend: C  │  Frontend: C++    ║\n";
    std::cout << "  ╚══════════════════════════════════════╝\n";
    std::cout << Color::RESET << "\n";
}

void InventoryManager::printMenu() const
{
    std::cout << Color::BOLD << Color::WHITE;
    std::cout << "  ┌──────────────────────────────┐\n";
    std::cout << "  │           M E N U            │\n";
    std::cout << "  ├──────────────────────────────┤\n";
    std::cout << "  │  1.  Add Item                │\n";
    std::cout << "  │  2.  View Item               │\n";
    std::cout << "  │  3.  Update Item             │\n";
    std::cout << "  │  4.  Delete Item             │\n";
    std::cout << "  │  5.  List All Items          │\n";
    std::cout << "  │  6.  Exit                    │\n";
    std::cout << "  └──────────────────────────────┘\n";
    std::cout << Color::RESET;
}

/*
 * printTableHeader()
 *   Prints the column headers and separator line for item tables.
 */
static void printTableHeader()
{
    std::cout << Color::BOLD << Color::CYAN;
    std::cout << "\n  "
              << std::left  << std::setw(COL_ID)    << "ID"
              << std::left  << std::setw(COL_NAME)   << "Name"
              << std::right << std::setw(COL_QTY)    << "Qty"
              << std::right << std::setw(COL_PRICE)  << "Price (INR)"
              << "\n";
    std::cout << "  " << std::string(COL_ID + COL_NAME + COL_QTY + COL_PRICE, '-') << "\n";
    std::cout << Color::RESET;
}

/*
 * printItem()
 *   Formats a single Item as a table row.
 */
static void printItem(const Item& item)
{
    std::cout << Color::WHITE << "  "
              << std::left  << std::setw(COL_ID)    << item.id
              << std::left  << std::setw(COL_NAME)   << item.name
              << std::right << std::setw(COL_QTY)    << item.quantity
              << std::right << std::setw(COL_PRICE - 4) << std::fixed
              << std::setprecision(2) << item.price << "  INR"
              << "\n" << Color::RESET;
}

/*
 * printSuccess() / printError()
 *   Standardised status messages.
 */
static void printSuccess(const std::string& msg)
{
    std::cout << Color::GREEN << "\n  ✔  " << msg << "\n" << Color::RESET;
}

static void printError(const std::string& msg)
{
    std::cout << Color::RED << "\n  ✘  " << msg << "\n" << Color::RESET;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Menu handlers
 * ═══════════════════════════════════════════════════════════════════════════ */

void InventoryManager::handleAdd()
{
    std::cout << Color::YELLOW << Color::BOLD << "\n  [ ADD ITEM ]\n" << Color::RESET;

    Item item;
    std::memset(&item, 0, sizeof(Item));

    item.id = readInt("  Enter ID        : ");
    if (item.id <= 0) { printError("ID must be a positive integer."); return; }

    std::string name = readString("  Enter Name      : ");
    if (name.length() >= NAME_MAX_LEN) {
        printError("Name too long (max " + std::to_string(NAME_MAX_LEN - 1) + " characters).");
        return;
    }
    std::strncpy(item.name, name.c_str(), NAME_MAX_LEN - 1);
    item.name[NAME_MAX_LEN - 1] = '\0';

    item.quantity = readInt("  Enter Quantity  : ");
    if (item.quantity < 0) { printError("Quantity cannot be negative."); return; }

    item.price = readFloat("  Enter Price     : ");
    if (item.price < 0.0f) { printError("Price cannot be negative."); return; }

    item.is_deleted = 0;

    if (add_item(&item))
        printSuccess("Item #" + std::to_string(item.id) + " added successfully.");
    else
        printError("Failed to add item. ID may already exist or I/O error occurred.");
}

void InventoryManager::handleView()
{
    std::cout << Color::YELLOW << Color::BOLD << "\n  [ VIEW ITEM ]\n" << Color::RESET;

    int id = readInt("  Enter Item ID   : ");
    if (id <= 0) { printError("ID must be a positive integer."); return; }

    Item item;
    if (get_item(id, &item)) {
        printTableHeader();
        printItem(item);
    } else {
        printError("Item #" + std::to_string(id) + " not found.");
    }
}

void InventoryManager::handleUpdate()
{
    std::cout << Color::YELLOW << Color::BOLD << "\n  [ UPDATE ITEM ]\n" << Color::RESET;

    int id = readInt("  Enter Item ID to update : ");
    if (id <= 0) { printError("ID must be a positive integer."); return; }

    /* Fetch existing record first so user can keep fields by pressing Enter
       (advanced UX) – for simplicity we just re-prompt all fields here.    */
    Item existing;
    if (!get_item(id, &existing)) {
        printError("Item #" + std::to_string(id) + " not found.");
        return;
    }

    std::cout << Color::DIM << "  Current values shown in [brackets]. Press Enter to keep.\n"
              << Color::RESET;

    /* Helper lambda to show current value hint */
    auto hint = [](const std::string& current) -> std::string {
        return " [" + current + "] : ";
    };

    /* Name */
    std::cout << "  Name" << hint(std::string(existing.name));
    std::string line;
    std::getline(std::cin, line);
    if (!line.empty()) {
        /* strip whitespace */
        size_t s = line.find_first_not_of(" \t");
        size_t e = line.find_last_not_of(" \t");
        if (s != std::string::npos) line = line.substr(s, e - s + 1);
    }
    if (line.empty()) line = std::string(existing.name);
    if (line.length() >= NAME_MAX_LEN) {
        printError("Name too long."); return;
    }
    std::strncpy(existing.name, line.c_str(), NAME_MAX_LEN - 1);
    existing.name[NAME_MAX_LEN - 1] = '\0';

    /* Quantity */
    std::cout << "  Quantity" << hint(std::to_string(existing.quantity));
    std::getline(std::cin, line);
    if (!line.empty()) {
        try {
            int q = std::stoi(line);
            if (q < 0) { printError("Quantity cannot be negative."); return; }
            existing.quantity = q;
        } catch (...) { printError("Invalid quantity."); return; }
    }

    /* Price */
    std::cout << "  Price   " << hint(std::to_string(existing.price));
    std::getline(std::cin, line);
    if (!line.empty()) {
        try {
            float p = std::stof(line);
            if (p < 0.0f) { printError("Price cannot be negative."); return; }
            existing.price = p;
        } catch (...) { printError("Invalid price."); return; }
    }

    if (update_item(id, &existing))
        printSuccess("Item #" + std::to_string(id) + " updated successfully.");
    else
        printError("Update failed. I/O error or validation failed.");
}

void InventoryManager::handleDelete()
{
    std::cout << Color::YELLOW << Color::BOLD << "\n  [ DELETE ITEM ]\n" << Color::RESET;

    int id = readInt("  Enter Item ID to delete : ");
    if (id <= 0) { printError("ID must be a positive integer."); return; }

    /* Confirm before deleting */
    std::cout << Color::RED << "  Are you sure you want to delete item #"
              << id << "? (y/N) : " << Color::RESET;
    std::string confirm;
    std::getline(std::cin, confirm);
    if (confirm != "y" && confirm != "Y") {
        std::cout << Color::DIM << "  Deletion cancelled.\n" << Color::RESET;
        return;
    }

    if (delete_item(id))
        printSuccess("Item #" + std::to_string(id) + " deleted (soft delete).");
    else
        printError("Item #" + std::to_string(id) + " not found or already deleted.");
}

void InventoryManager::handleList()
{
    std::cout << Color::YELLOW << Color::BOLD << "\n  [ LIST ALL ITEMS ]\n" << Color::RESET;

    /* Ask for sort preference */
    std::cout << "  Sort by: (1) ID  (2) Name  [default=1] : ";
    std::string sortChoice;
    std::getline(std::cin, sortChoice);
    bool sortByName = (sortChoice == "2");

    /* Use std::vector<Item> for STL compliance */
    std::vector<Item> buffer(MAX_ITEMS);
    int count = list_items(buffer.data(), MAX_ITEMS);
    buffer.resize(static_cast<size_t>(count));   /* shrink to actual count  */

    if (count == 0) {
        std::cout << Color::DIM << "\n  No items in inventory.\n" << Color::RESET;
        return;
    }

    /* std::sort with a lambda comparator */
    if (sortByName) {
        std::sort(buffer.begin(), buffer.end(), [](const Item& a, const Item& b) {
            return std::strcmp(a.name, b.name) < 0;
        });
    } else {
        std::sort(buffer.begin(), buffer.end(), [](const Item& a, const Item& b) {
            return a.id < b.id;
        });
    }

    printTableHeader();
    for (const Item& item : buffer)
        printItem(item);

    std::cout << Color::DIM << "\n  " << count << " item(s) found.\n" << Color::RESET;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Main run loop
 * ═══════════════════════════════════════════════════════════════════════════ */

void InventoryManager::run()
{
    printBanner();

    while (true) {
        printMenu();
        int choice = readInt("\n  Enter choice : ");
        std::cout << "\n";

        switch (choice) {
            case 1: handleAdd();    break;
            case 2: handleView();   break;
            case 3: handleUpdate(); break;
            case 4: handleDelete(); break;
            case 5: handleList();   break;
            case 6:
                std::cout << Color::CYAN << "\n  Goodbye! Data saved to inventory.dat\n\n"
                          << Color::RESET;
                return;
            default:
                printError("Invalid choice. Please select 1–6.");
        }

        std::cout << "\n";
    }
}
CPP_EOF

echo "  [OK] src/InventoryManager.cpp"

# =============================================================================
# FILE 4: src/InventoryManager.h  (header for the C++ class)
# =============================================================================
cat > "$PROJECT_DIR/include/InventoryManager.h" << 'IMHDR_EOF'
/*
 * InventoryManager.h
 * ------------------
 * Declaration of the C++ frontend class.
 * Must NOT be included from C source files.
 */

#ifndef INVENTORY_MANAGER_H
#define INVENTORY_MANAGER_H

class InventoryManager {
public:
    InventoryManager();
    ~InventoryManager();

    /* Main entry point – runs the interactive menu loop until user exits. */
    void run();

private:
    /* One method per menu option; keeps run() clean and readable. */
    void handleAdd();
    void handleView();
    void handleUpdate();
    void handleDelete();
    void handleList();

    /* UI helpers */
    void printBanner() const;
    void printMenu()   const;
};

#endif /* INVENTORY_MANAGER_H */
IMHDR_EOF

echo "  [OK] include/InventoryManager.h"

# =============================================================================
# FILE 5: src/main.cpp
# =============================================================================
cat > "$PROJECT_DIR/src/main.cpp" << 'MAIN_EOF'
/*
 * main.cpp
 * --------
 * Entry point for the Hybrid Inventory Manager.
 *
 * Responsibilities:
 *   1. Instantiate InventoryManager (C++ object).
 *   2. Delegate all execution to InventoryManager::run().
 *   3. Return EXIT_SUCCESS on clean exit.
 *
 * This file is intentionally minimal: all logic lives in the appropriate
 * layer (C backend or C++ InventoryManager).
 */

#include "InventoryManager.h"
#include <cstdlib>

int main()
{
    InventoryManager mgr;
    mgr.run();
    return EXIT_SUCCESS;
}
MAIN_EOF

echo "  [OK] src/main.cpp"

# =============================================================================
# FILE 6: Makefile
# =============================================================================
cat > "$PROJECT_DIR/Makefile" << 'MAKE_EOF'
# =============================================================================
# Makefile – Hybrid Inventory Manager
#
# Rules:
#   make          → build the executable (default)
#   make clean    → remove object files and the binary
#   make rebuild  → clean then build
#   make run      → build and immediately run
# =============================================================================

# ── Compiler & flags ─────────────────────────────────────────────────────────
CC      := gcc
CXX     := g++

# Strict warnings, debug symbols by default. Swap -g for -O2 in production.
CFLAGS  := -std=c11   -Wall -Wextra -Wpedantic -g -Iinclude
CXXFLAGS:= -std=c++17 -Wall -Wextra -Wpedantic -g -Iinclude

LDFLAGS :=             # no external libraries required

# ── Directories ──────────────────────────────────────────────────────────────
SRC_DIR := src
OBJ_DIR := obj
BIN     := inventory_manager

# ── Sources & objects ────────────────────────────────────────────────────────
C_SRCS   := $(SRC_DIR)/inventory.c
CXX_SRCS := $(SRC_DIR)/InventoryManager.cpp $(SRC_DIR)/main.cpp

C_OBJS   := $(patsubst $(SRC_DIR)/%.c,   $(OBJ_DIR)/%.o, $(C_SRCS))
CXX_OBJS := $(patsubst $(SRC_DIR)/%.cpp, $(OBJ_DIR)/%.o, $(CXX_SRCS))

ALL_OBJS := $(C_OBJS) $(CXX_OBJS)

# ── Default target ───────────────────────────────────────────────────────────
.PHONY: all clean rebuild run

all: $(OBJ_DIR) $(BIN)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

# Link: use g++ as the linker so the C++ runtime is included automatically.
$(BIN): $(ALL_OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)
	@echo ""
	@echo "  Build complete → ./$(BIN)"
	@echo ""

# Compile C source files with gcc
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c
	$(CC) $(CFLAGS) -c $< -o $@

# Compile C++ source files with g++
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -rf $(OBJ_DIR) $(BIN) inventory.dat
	@echo "  Cleaned."

rebuild: clean all

run: all
	./$(BIN)
MAKE_EOF

echo "  [OK] Makefile"

# =============================================================================
# FILE 7: README.md
# =============================================================================
cat > "$PROJECT_DIR/README.md" << 'README_EOF'
# Hybrid Inventory Manager

A production-quality console application demonstrating a **hybrid C / C++ architecture**:

| Layer       | Language | Responsibility                                      |
|-------------|----------|-----------------------------------------------------|
| Backend     | C (C11)  | Binary file I/O, struct-based storage, C API        |
| Frontend    | C++ (17) | Menu UI, input validation, STL, business logic ctrl |
| Persistence | Binary   | `inventory.dat` – survives process restarts         |

---

## Project Structure

```
HybridInventoryManager/
├── include/
│   ├── inventory.h          ← Shared C struct + extern "C" API declarations
│   └── InventoryManager.h   ← C++ class declaration
├── src/
│   ├── inventory.c          ← C backend (fread/fwrite/fseek, soft-delete)
│   ├── InventoryManager.cpp ← C++ frontend (menus, validation, std::vector/sort)
│   └── main.cpp             ← Entry point (6 lines)
├── Makefile
└── README.md
```

---

## Build Steps

### Prerequisites

| Tool  | Minimum Version |
|-------|-----------------|
| gcc   | 9.x             |
| g++   | 9.x             |
| make  | 3.81            |

On Ubuntu/Debian:
```bash
sudo apt update && sudo apt install build-essential -y
```

### Build

```bash
cd HybridInventoryManager
make          # compiles and links → ./inventory_manager
```

### Run

```bash
./inventory_manager
# or
make run
```

### Clean

```bash
make clean    # removes obj/, binary, and inventory.dat
```

---

## How It Works

### Binary File Format

Each record in `inventory.dat` is exactly `sizeof(Item)` bytes:

```
[ int id ][ char name[40] ][ int quantity ][ float price ][ int is_deleted ]
```

- Records are **never physically removed** (append-only growth).
- Deleted records have `is_deleted = 1` and are invisible to all queries.
- Updates use `fseek` to overwrite the record **in-place** at its byte offset.

### extern "C" Linkage

`inventory.h` wraps all function declarations in:
```c
#ifdef __cplusplus
extern "C" { ... }
#endif
```
This prevents C++ name-mangling so `g++` can link against the `gcc`-compiled
object file without linker errors.

---

## Test Cases

### Test 1 – Add a valid item

```
Menu → 1
ID       : 101
Name     : Wireless Mouse
Quantity : 50
Price    : 799.00
Expected : ✔ Item #101 added successfully.
```

### Test 2 – Reject duplicate ID

```
Menu → 1
ID       : 101   ← same ID as Test 1
Name     : Keyboard
...
Expected : ✘ Failed to add item. ID may already exist or I/O error occurred.
```

### Test 3 – View item / not found

```
Menu → 2
ID       : 999
Expected : ✘ Item #999 not found.
```

### Test 4 – Update and persist across restarts

```
Menu → 3
ID       : 101
Name     : [Wireless Mouse] → Gaming Mouse   (press Enter to keep quantity/price)
Expected : ✔ Item #101 updated successfully.

# Exit (6), then restart ./inventory_manager
Menu → 2 → ID 101
Expected : Row shows "Gaming Mouse" – confirming binary persistence.
```

### Test 5 – Soft delete and list

```
Menu → 1 → Add item ID 202, Name: USB Hub, Qty: 10, Price: 299.00
Menu → 4 → Delete ID 202 → confirm y
Menu → 5 → List All Items
Expected : ID 202 / USB Hub does NOT appear in the table.
           (Record still exists in inventory.dat with is_deleted=1)
```

---

## Sample Output

```
  ╔══════════════════════════════════════╗
  ║     HYBRID INVENTORY MANAGER  v1.0   ║
  ║      Backend: C  │  Frontend: C++    ║
  ╚══════════════════════════════════════╝

  ┌──────────────────────────────┐
  │           M E N U            │
  ├──────────────────────────────┤
  │  1.  Add Item                │
  │  2.  View Item               │
  │  3.  Update Item             │
  │  4.  Delete Item             │
  │  5.  List All Items          │
  │  6.  Exit                    │
  └──────────────────────────────┘

  Enter choice : 5

  [ LIST ALL ITEMS ]
  Sort by: (1) ID  (2) Name  [default=1] :

  ID    Name                  Qty    Price (INR)
  --------------------------------------------------
  101   Wireless Mouse         50      799.00  INR
  103   USB-C Hub              15      499.50  INR
  107   Mechanical Keyboard    30     1299.00  INR

  3 item(s) found.
```

---

## Architecture Notes

- **No segfaults**: All pointer arguments validated before use; `std::cin` error
  states cleared after every failed extraction.
- **No memory leaks**: No heap allocations. `std::vector` manages its own memory.
- **Cross-platform**: Standard C11 / C++17; should build on Linux, macOS, and
  Windows (MinGW/MSYS2) with minor terminal-colour caveats.
README_EOF

echo "  [OK] README.md"

# =============================================================================
# Done
# =============================================================================
echo ""
echo ">>> Project created in ./$PROJECT_DIR/"
echo ""
echo "    To build and run:"
echo "      cd $PROJECT_DIR"
echo "      make"
echo "      ./inventory_manager"
echo ""
