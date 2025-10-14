// BotSearchService.cls (v9d — multi-list, services-aware, fixed SOQL)
public with sharing class BotSearchService {

    // ===== INPUT =====
    public class SearchRequest {
        @InvocableVariable(label='Location')   public String location;   // city, ZIP, or part of name
        @InvocableVariable(label='Event Type') public String eventType;  // optional: Medical Camp / Blood Drive / Disaster Relief
    }

    // ===== OUTPUT =====
    public class SearchResponse {
        @InvocableVariable(label='Message')   public String message;   // multi-line summary
        @InvocableVariable(label='Camp Id')   public Id campId;        // first (soonest) result for "book it"
        @InvocableVariable(label='Camp Name') public String campName;  // for booking confirmation text
        @InvocableVariable(label='Map URL')   public String mapUrl;    // directions for the first result
    }

    @InvocableMethod(label='MTN Find Medical Camps v9b')
    public static List<SearchResponse> searchForCamps(List<SearchRequest> reqs) {
        List<SearchResponse> out = new List<SearchResponse>();
        try {
            // ---- validate input ----
            if (reqs == null || reqs.isEmpty() || String.isBlank(reqs[0].location)) {
                out.add(msgOnly('Please share a city or ZIP (e.g., Pleasanton or 94566).'));
                return out;
            }
            final String q   = reqs[0].location.trim();
            final String key = '%' + q + '%';

            // normalize optional event type
            String et = normalizeEventType(reqs[0].eventType);

            // ---- find up to 3 upcoming camps by location (+ optional type filter) ----
            Integer take = 3;
            List<Medical_Camp__c> camps;

            if (et == null) {
                // no event-type filter: any camp that matches the location
                camps = [
                    SELECT Id, Name, Camp_Date__c, City__c, Postal_Code__c, Active__c,
                           Location__Latitude__s, Location__Longitude__s
                    FROM Medical_Camp__c
                    WHERE Active__c = TRUE
                      AND (Name LIKE :key OR City__c LIKE :key OR Postal_Code__c LIKE :key)
                    ORDER BY Camp_Date__c ASC NULLS LAST, Name ASC
                    LIMIT :take
                ];
            } else {
                // restrict to camps that have at least one Event_Service__c of the requested type
                camps = [
                    SELECT Id, Name, Camp_Date__c, City__c, Postal_Code__c, Active__c,
                           Location__Latitude__s, Location__Longitude__s
                    FROM Medical_Camp__c
                    WHERE Active__c = TRUE
                      AND (Name LIKE :key OR City__c LIKE :key OR Postal_Code__c LIKE :key)
                      AND Id IN (
                          SELECT Medical_Camp__c
                          FROM Event_Service__c
                          WHERE Type__c = :et
                      )
                    ORDER BY Camp_Date__c ASC NULLS LAST, Name ASC
                    LIMIT :take
                ];
            }

            if (camps.isEmpty()) {
                String kind = (et == null) ? 'events' : et.toLowerCase();
                out.add(msgOnly('No ' + kind + ' found near "' + q + '". Try another city or ZIP.'));
                return out;
            }

            // ---- fetch earliest service per camp (to label each line with a type) ----
            Set<Id> campIds = new Set<Id>();
            for (Medical_Camp__c c : camps) campIds.add(c.Id);

            Map<Id, Event_Service__c> firstServiceByCamp = new Map<Id, Event_Service__c>();
            if (!campIds.isEmpty()) {
                List<Event_Service__c> svcRows;
                if (et == null) {
                    svcRows = [
                        SELECT Id, Medical_Camp__c, Type__c, Hours__c
                        FROM Event_Service__c
                        WHERE Medical_Camp__c IN :campIds
                        ORDER BY Medical_Camp__c, Hours__c ASC
                    ];
                } else {
                    svcRows = [
                        SELECT Id, Medical_Camp__c, Type__c, Hours__c
                        FROM Event_Service__c
                        WHERE Medical_Camp__c IN :campIds
                          AND Type__c = :et
                        ORDER BY Medical_Camp__c, Hours__c ASC
                    ];
                }
                for (Event_Service__c s : svcRows) {
                    if (!firstServiceByCamp.containsKey(s.Medical_Camp__c)) {
                        firstServiceByCamp.put(s.Medical_Camp__c, s);
                    }
                }
            }

            // ---- build message lines ----
            List<String> lines = new List<String>();
            for (Medical_Camp__c c : camps) {
                String dateTxt  = (c.Camp_Date__c == null) ? 'TBD' : c.Camp_Date__c.format();
                String whereTxt = String.isBlank(c.City__c) ? '' : ' (' + c.City__c + ')';
                String typeTxt  = 'Event';
                Event_Service__c svc = firstServiceByCamp.get(c.Id);
                if (svc != null && !String.isBlank(svc.Type__c)) typeTxt = svc.Type__c;

                String mapUrl = buildMapUrl(c);
                lines.add('• ' + c.Name + ' — ' + dateTxt + whereTxt + ' • ' + typeTxt
                          + ' • Directions: ' + mapUrl);
            }

            String header = (et == null)
                ? 'Here are upcoming events (camps, blood drives, relief) near "' + q + '":'
                : 'Here are upcoming ' + et.toLowerCase() + 's near "' + q + '":';

            Medical_Camp__c first = camps[0];

            SearchResponse r = new SearchResponse();
            r.campId   = first.Id;
            r.campName = first.Name;
            r.mapUrl   = buildMapUrl(first);
            r.message  = header + '\n' + String.join(lines, '\n')
                       + '\n\nReply with an event name to book, or say "book it" to book the first one.';
            out.add(r);
            return out;

        } catch (Exception e) {
            out.add(msgOnly('Sorry — I had trouble searching right now. Please try again or try a different city.'));
            return out;
        }
    }

    // ===== helpers =====
    private static SearchResponse msgOnly(String m) {
        SearchResponse r = new SearchResponse(); r.message = m; return r;
    }

    // Normalize the optional event type.
    // IMPORTANT: "camp/camps/health camp(s)" => null (no filter) so we show all event types.
    private static String normalizeEventType(String raw) {
        if (String.isBlank(raw)) return null;
        String et = raw.trim();
        if (et.equalsIgnoreCase('camp') || et.equalsIgnoreCase('camps')
         || et.equalsIgnoreCase('health camp') || et.equalsIgnoreCase('health camps')) {
            return null; // generic ask => broaden to all types
        }
        if (et.equalsIgnoreCase('blood') || et.equalsIgnoreCase('blood drive')) return 'Blood Drive';
        if (et.equalsIgnoreCase('relief') || et.equalsIgnoreCase('disaster') || et.equalsIgnoreCase('disaster relief')) return 'Disaster Relief';
        if (et.equalsIgnoreCase('medical camp') || et.equalsIgnoreCase('medical')) return 'Medical Camp';
        // otherwise pass through (assumes it matches your picklist)
        return et;
    }

    private static String buildMapUrl(Medical_Camp__c c) {
        if (c.Location__Latitude__s != null && c.Location__Longitude__s != null) {
            return 'https://www.google.com/maps/search/?api=1&query='
                 + String.valueOf(c.Location__Latitude__s) + ',' + String.valueOf(c.Location__Longitude__s);
        }
        String q = ((c.Name != null ? c.Name : '') + ' ' + (c.City__c != null ? c.City__c : '')).trim();
        return 'https://www.google.com/maps/search/?api=1&query=' + EncodingUtil.urlEncode(q, 'UTF-8');
    }
}