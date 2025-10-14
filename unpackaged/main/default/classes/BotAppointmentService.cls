// BotAppointmentService.cls
public with sharing class BotAppointmentService {

    public class BookRequest {
        @InvocableVariable(label='Camp Id')        public Id campId;
        @InvocableVariable(label='Attendee Name')  public String attendeeName;
        @InvocableVariable(label='Phone')          public String phone;
        @InvocableVariable(label='Reminder Opt-In')public Boolean optIn; // null => default true
    }
    public class BookResponse {
        @InvocableVariable(label='Message')        public String message;
        @InvocableVariable(label='Appointment Id') public Id appointmentId;
        @InvocableVariable(label='Waitlisted')     public Boolean waitlisted;
    }

    @InvocableMethod(label='MTN Book Appointment')
    public static List<BookResponse> book(List<BookRequest> reqs) {
        List<BookResponse> out = new List<BookResponse>();
        if (reqs == null || reqs.isEmpty()) {
            out.add(resp(null, false,
                'I couldn’t find the booking details. Please try again.'));
            return out;
        }

        // Collect camp Ids we need to verify.
        Set<Id> campIds = new Set<Id>();
        for (BookRequest r : reqs) if (r != null && r.campId != null) campIds.add(r.campId);

        Map<Id, Medical_Camp__c> campById = new Map<Id, Medical_Camp__c>();
        if (!campIds.isEmpty()) {
            for (Medical_Camp__c c : [
                SELECT Id, Name, Camp_Date__c, City__c, Slots_Remaining__c, Active__c
                FROM Medical_Camp__c
                WHERE Id IN :campIds
            ]) campById.put(c.Id, c);
        }

        // Build records to insert + keep parallel lists
        List<Appointment__c> toInsert = new List<Appointment__c>();
        List<Boolean> waitFlags      = new List<Boolean>();
        List<Medical_Camp__c> campSeq= new List<Medical_Camp__c>(); // aligns with toInsert

        for (BookRequest r : reqs) {
            if (r == null || r.campId == null) {
                out.add(resp(null, false, 'Please choose a medical camp to book.'));
                continue;
            }
            Medical_Camp__c camp = campById.get(r.campId);
            if (camp == null || camp.Active__c != true) {
                out.add(resp(null, false,
                    'That camp was not found or is not active. Please choose another.'));
                continue;
            }

            Integer slots = (camp.Slots_Remaining__c == null) ? 0 : Integer.valueOf(camp.Slots_Remaining__c);
            Boolean waitlist = (slots <= 0);

            Appointment__c a = new Appointment__c();
            a.Medical_Camp__c    = camp.Id;
            a.Attendee_Name__c   = String.isBlank(r.attendeeName) ? 'Guest' : r.attendeeName.trim();
            a.Phone__c           = normalizePhone(r.phone);              // cleanup
            a.Reminder_Opt_In__c = (r.optIn == null) ? true : r.optIn;   // default TRUE when null
            a.Status__c          = 'Booked';
            a.Waitlist__c        = waitlist;

            toInsert.add(a);
            waitFlags.add(waitlist);
            campSeq.add(camp);
        }

        // Try insert and catch any validation/required-field errors
        if (!toInsert.isEmpty()) {
            try {
                insert toInsert;
            } catch (DmlException dml) {
                // Fail all corresponding requests gracefully
                for (Integer i = 0; i < toInsert.size(); i++) {
                    Medical_Camp__c camp = campSeq[i];
                    out.add(resp(null, waitFlags[i],
                        'Sorry, I couldn’t complete the booking for "' +
                        (camp != null ? camp.Name : 'this camp') +
                        '". Please check details and try again.'));
                }
                return out;
            }
        }

        // Success responses (parallel to lists above)
        for (Integer i = 0; i < toInsert.size(); i++) {
            Appointment__c appt = toInsert[i];
            Medical_Camp__c camp = campSeq[i];
            Boolean waitlist = waitFlags[i];

            String dateTxt = (camp.Camp_Date__c == null) ? 'TBD' : camp.Camp_Date__c.format();
            String cityTxt = String.isBlank(camp.City__c) ? '' : ' (' + camp.City__c + ')';

            String msg = waitlist
                ? 'You’re on the waitlist for "' + camp.Name + '" on ' + dateTxt + cityTxt + '. We’ll notify you if a slot opens.'
                : 'Your appointment for "' + camp.Name + '" on ' + dateTxt + cityTxt + ' is booked.' +
                  (String.isBlank(appt.Phone__c) ? '' : ' You’ll receive SMS reminders. Reply STOP to opt out.');

            out.add(resp(appt.Id, waitlist, msg));
        }

        // If some inputs were skipped earlier (no campId, inactive, etc.), their
        // responses were already appended. Return everything.
        return out;
    }

    // ---- helpers ----
    private static BookResponse resp(Id id, Boolean wl, String m) {
        BookResponse br = new BookResponse();
        br.appointmentId = id; br.waitlisted = wl; br.message = m; return br;
    }

    // Strip non-digits; keep leading + for E.164 if present.
    private static String normalizePhone(String raw) {
        if (String.isBlank(raw)) return null;
        String r = raw.trim();
        if (r.startsWith('+')) {
            return '+' + r.replaceAll('[^0-9]', '');
        }
        return r.replaceAll('[^0-9]', '');
    }
}