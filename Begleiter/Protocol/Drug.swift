import Foundation

/// A drug as a clinical concept, independent of dose/schedule/administration.
///
/// Used in two places:
/// 1. `PhaseMetadata.drugs` — the canonical drug list per phase.
/// 2. (Later iteration) extracted from journal entries by Gemma.
///
/// `atcCode` is the WHO ATC classification (e.g. "L01CA02" for vincristine).
/// It is optional because the parent UI does not need it; it exists so the
/// retrieval layer can later disambiguate "Cyto" → cytarabine vs cyclophosphamide.
struct Drug: Codable, Hashable, Sendable {
    let name: String           // canonical English INN, e.g. "vincristine"
    let germanLabel: String    // e.g. "Vincristin"
    let englishLabel: String   // e.g. "Vincristine"
    let atcCode: String?       // e.g. "L01CA02"
}

// MARK: - Canonical drugs in the BFM 2017 protocol
//
// CLINICAL-REVIEW: this is the public-information drug list for the protocol.
// ATC codes are from the WHO ATC index. Names follow INN. Advisor should
// confirm German spelling conventions (e.g. "Pegaspargase" vs "PEG-Asparaginase").
extension Drug {
    static let vincristine = Drug(
        name: "vincristine",
        germanLabel: "Vincristin",
        englishLabel: "Vincristine",
        atcCode: "L01CA02"
    )

    static let dexamethasone = Drug(
        name: "dexamethasone",
        germanLabel: "Dexamethason",
        englishLabel: "Dexamethasone",
        atcCode: "H02AB02"
    )

    static let prednisone = Drug(
        name: "prednisone",
        germanLabel: "Prednison",
        englishLabel: "Prednisone",
        atcCode: "H02AB07"
    )

    static let pegaspargase = Drug(
        name: "pegaspargase",
        germanLabel: "PEG-Asparaginase",
        englishLabel: "Pegaspargase",
        atcCode: "L01XX24"
    )

    static let methotrexate = Drug(
        name: "methotrexate",
        germanLabel: "Methotrexat",
        englishLabel: "Methotrexate",
        atcCode: "L01BA01"
    )

    static let cyclophosphamide = Drug(
        name: "cyclophosphamide",
        germanLabel: "Cyclophosphamid",
        englishLabel: "Cyclophosphamide",
        atcCode: "L01AA01"
    )

    static let cytarabine = Drug(
        name: "cytarabine",
        germanLabel: "Cytarabin",
        englishLabel: "Cytarabine",
        atcCode: "L01BC01"
    )

    static let mercaptopurine6 = Drug(
        name: "mercaptopurine",
        germanLabel: "6-Mercaptopurin",
        englishLabel: "6-Mercaptopurine",
        atcCode: "L01BB02"
    )

    static let doxorubicin = Drug(
        name: "doxorubicin",
        germanLabel: "Doxorubicin",
        englishLabel: "Doxorubicin",
        atcCode: "L01DB01"
    )

    static let daunorubicin = Drug(
        name: "daunorubicin",
        germanLabel: "Daunorubicin",
        englishLabel: "Daunorubicin",
        atcCode: "L01DB02"
    )

    static let etoposide = Drug(
        name: "etoposide",
        germanLabel: "Etoposid",
        englishLabel: "Etoposide",
        atcCode: "L01CB01"
    )

    static let thioguanine = Drug(
        name: "thioguanine",
        germanLabel: "Thioguanin",
        englishLabel: "Thioguanine",
        atcCode: "L01BB03"
    )

    static let ifosfamide = Drug(
        name: "ifosfamide",
        germanLabel: "Ifosfamid",
        englishLabel: "Ifosfamide",
        atcCode: "L01AA06"
    )

    static let blinatumomab = Drug(
        name: "blinatumomab",
        germanLabel: "Blinatumomab",
        englishLabel: "Blinatumomab",
        atcCode: "L01FX07"
    )

    static let bortezomib = Drug(
        name: "bortezomib",
        germanLabel: "Bortezomib",
        englishLabel: "Bortezomib",
        atcCode: "L01XG01"
    )
}
